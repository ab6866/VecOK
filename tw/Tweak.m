// ===========================================================================
//  VecOK — tweak build
//  作者: 6866
//
//  纯 tweak 实现（标准 Theos 工程，Rootless + RootHide 双包）
//  —— 不再改动磁盘上的任何二进制，因此不存在"改签名导致启动闪退"的风险。
//
//  目标: 应用内一项布尔状态判定
//
//  ★ 静态取证结论（样本）
//    the flag byte lives in a Swift async 协程帧内 +0x18a（不在任何 ObjC 对象里 ——
//    所有类的 instanceSize 都 < 0x190，目标类仅 0x58，其 Pro 相关 ivar 偏移全为 0）。
//    single write site: 0x10008f08c  strb w0,[x22,#0x18a]
//    reached from 4 exits via b 0x10008f070:
//        2× mov  w0,#1        (always-true path)
//        2x and  w0,w19,#1    (gate)
//    6 read sites: 3x derives an active state, 3x syncs a shared flag.
//    => the gate converges on those two sites.
//
//  ★ 本 tweak 的三层实现（由外到内，互不重叠）
//    L1  ObjC 属性 getter 交换：目标类的 Pro 相关属性访问器 → 恒真。
//        纯运行期，不写代码页，W^X 严格环境同样有效。
//    L2  NSUserDefaults 严格白名单：只拦那一个共享 Pro 位（含 App Group 套件）。
//    L3  Keychain 终身项预置：让 App 自身的"终身回退"路径原生成立。
//
//  ★ 遵守的硬性纪律
//    - ctor 只做最小动作（注册延迟初始化），绝不在 dyld 构造期碰 objc/UI/文件系统高层 API
//    - 所有替换实现都能 100% 链回原实现；未命中时一律"放行给原实现"，绝不返回空值
//    - 严格白名单，不做任何"键名含某词即拦截"的模糊匹配；不 hook 写方法
//    - 全程诊断日志：命中计数 / 候选列表 / 回读确认 / 未找到原实现的告警
// ===========================================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <string.h>

// ---------------------------------------------------------------- 可配置常量（由构建期注入）
#ifndef OK_TARGET_CLASS
#define OK_TARGET_CLASS "OkStore"
#endif
#ifndef OK_PRO_KEY
#define OK_PRO_KEY "ok.pro.flag"
#endif
#ifndef OK_KC_SERVICE
#define OK_KC_SERVICE "ok.pro.svc"
#endif
#ifndef OK_KC_ACCOUNT
#define OK_KC_ACCOUNT "ok.pro.acct"
#endif
#ifndef OK_APP_GROUP
#define OK_APP_GROUP "group.ok.shared"
#endif

// ---------------------------------------------------------------- 日志
static NSString *g_logPath = nil;

static void oklog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[VecOK] %@", s);

    if (!g_logPath) {
        NSString *home = NSHomeDirectory();
        NSArray *c = @[
            [home stringByAppendingPathComponent:@"Documents/vecok.log"],
            @"/tmp/vecok.log",
        ];
        for (NSString *p in c) {
            NSFileManager *fm = [NSFileManager defaultManager];
            [fm createDirectoryAtPath:[p stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:NULL];
            if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:nil attributes:NULL];
            if ([fm fileExistsAtPath:p]) { g_logPath = p; break; }
        }
        if (g_logPath) oklog(@"log path = %@", g_logPath);
    }
    if (!g_logPath) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
    if (!fh) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                      [df stringFromDate:[NSDate date]], s];
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *e) {}
    [fh closeFile];
}

// ---------------------------------------------------------------- 运行期辅助
#define OK_MSG0(o, s)          ((id (*)(id, SEL))objc_msgSend)((o), sel_registerName(s))
#define OK_MSG1(o, s, a)       ((id (*)(id, SEL, id))objc_msgSend)((o), sel_registerName(s), (a))

static id ok_str(const char *utf8) {
    return OK_MSG1([NSString alloc], "initWithUTF8String:", (__bridge id)(void *)utf8);
}

static BOOL ok_is_str(id obj, const char *utf8) {
    if (!obj) return NO;
    // 按 sel 兜底：不假设具体类
    SEL sel = sel_registerName("isEqualToString:");
    Method m = class_getInstanceMethod([NSString class], sel);
    if (!m) return NO;
    IMP imp = method_getImplementation(m);
    id want = ok_str(utf8);
    if (!want) return NO;
    return ((BOOL (*)(id, SEL, id))imp)(obj, sel, want) ? YES : NO;
}

// ---------------------------------------------------------------- L1：Pro 属性 getter 交换
static BOOL ok_ret_yes(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static NSInteger ok_ret_one_int(id self, SEL _cmd) { (void)self; (void)_cmd; return 1; }
static id ok_ret_one_obj(id self, SEL _cmd) { (void)self; (void)_cmd; return @1; }

// 只有"确实由该类自己实现"的方法才交换；记录原实现以便链回
typedef struct { Class cls; SEL sel; IMP orig; const char *name; } ok_hook_t;
static ok_hook_t g_hooks[64];
static int g_hookCount = 0;

static BOOL ok_install(Class cls, const char *selname, IMP repl, const char *retkind) {
    SEL sel = sel_registerName(selname);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == repl) return NO;

    // 探测返回类型，避免把非布尔型 getter 错误替换成 YES
    const char *types = method_getTypeEncoding(m);
    if (retkind) {
        if (types && types[0] != retkind[0]) {
            oklog(@"L1: 跳过 %s -%s（返回类型 %c 与预期 %c 不符）",
                  class_getName(cls), selname,
                  types[0] ? types[0] : '?', retkind[0]);
            return NO;
        }
    }
    IMP prev = method_setImplementation(m, repl);
    if (!prev) return NO;
    if (g_hookCount < 64) {
        g_hooks[g_hookCount].cls = cls;
        g_hooks[g_hookCount].sel = sel;
        g_hooks[g_hookCount].orig = prev;
        g_hooks[g_hookCount].name = selname;
        g_hookCount++;
    }
    oklog(@"L1: 交换 %s -%s（原实现已保存）", class_getName(cls), selname);
    return YES;
}

// getter 链回：未命中即放行给原实现（绝不返回空值）
#define OK_CHAIN_BOOL(name, selname)                                  \
    static BOOL name(id self, SEL _cmd) {                             \
        for (int i = 0; i < g_hookCount; i++)                         \
            if (g_hooks[i].sel == _cmd && g_hooks[i].orig)            \
                return ((BOOL (*)(id, SEL))g_hooks[i].orig)(self, _cmd); \
        return YES;                                                   \
    }

static void ok_swizzle_pro(void) {
    Class cls = objc_getClass(OK_TARGET_CLASS);
    if (!cls) {
        // 按名兜底：目标类可能尚未加载或被改名
        oklog(@"L1: 未找到类 %s —— 列出所有候选：", OK_TARGET_CLASS);
        unsigned n = 0;
        Class *list = objc_copyClassList(&n);
        int shown = 0;
        if (list) {
            for (unsigned i = 0; i < n && shown < 20; i++) {
                const char *cn = class_getName(list[i]);
                if (strstr(cn, "Store") || strstr(cn, "Pro") || strstr(cn, "Purchase")) {
                    oklog(@"    候选: %s", cn);
                    shown++;
                }
            }
            free(list);
        }
        if (!shown) oklog(@"    无任何含 Store/Pro/Purchase 的类");
        return;
    }
    oklog(@"L1: 目标类 %s 已定位", class_getName(cls));

    // 逐个探测：只有真实存在且返回 BOOL 的才交换
    static const char *cands[] = {
        "isPro", "hasProAccess", "hasProAccessValue", "isProUser",
        "isLifetimePro", "lifetimeUnlocked", "isPremium", "hasPremium",
        "isSubscribed", "isActive",
    };
    int hit = 0;
    for (unsigned i = 0; i < sizeof(cands) / sizeof(cands[0]); i++) {
        if (ok_install(cls, cands[i], (IMP)ok_ret_yes, "B")) hit++;
    }
    oklog(@"L1: Pro 属性 getter 交换命中 %d 个（候选 %zu 个，未命中不视为失败）",
          hit, sizeof(cands) / sizeof(cands[0]));
}

// ---------------------------------------------------------------- L2：NSUserDefaults 严格白名单
static IMP o_boolForKey, o_objectForKey, o_stringForKey;
static BOOL g_ud_hooked = NO;

static BOOL ok_is_gate(id key) { return ok_is_str(key, OK_PRO_KEY); }

static BOOL h_boolForKey(id s, SEL c, id k) {
    if (ok_is_gate(k)) { oklog(@"L2: boolForKey:%s -> YES", OK_PRO_KEY); return YES; }
    return ((BOOL (*)(id, SEL, id))o_boolForKey)(s, c, k);   // 放行给原实现
}
static id h_objectForKey(id s, SEL c, id k) {
    if (ok_is_gate(k)) { oklog(@"L2: objectForKey:%s -> @YES", OK_PRO_KEY); return @YES; }
    return ((id (*)(id, SEL, id))o_objectForKey)(s, c, k);
}
static id h_stringForKey(id s, SEL c, id k) {
    if (ok_is_gate(k)) { oklog(@"L2: stringForKey:%s -> \"1\"", OK_PRO_KEY); return @"1"; }
    return ((id (*)(id, SEL, id))o_stringForKey)(s, c, k);
}

// 按类匹配 + 按 sel 兜底（hook 可能装在基类而实例是私有子类）
static int ok_hook_sel(Class c, const char *selname, IMP repl, IMP *slot) {
    Method m = class_getInstanceMethod(c, sel_registerName(selname));
    if (!m) return 0;
    if (method_getImplementation(m) == repl) return 0;
    IMP prev = method_setImplementation(m, repl);
    if (prev && slot && !*slot) *slot = prev;
    return prev ? 1 : 0;
}

static void ok_hook_ud(void) {
    Class base = [NSUserDefaults class];
    int n = 0;
    n += ok_hook_sel(base, "boolForKey:",   (IMP)h_boolForKey,   &o_boolForKey);
    n += ok_hook_sel(base, "objectForKey:", (IMP)h_objectForKey, &o_objectForKey);
    n += ok_hook_sel(base, "stringForKey:", (IMP)h_stringForKey, &o_stringForKey);

    // 子类兜底
    int subs = 0;
    unsigned cnt = 0;
    Class *list = objc_copyClassList(&cnt);
    if (list) {
        for (unsigned i = 0; i < cnt; i++) {
            Class c = list[i];
            if (c == base) continue;
            BOOL isSub = NO;
            for (Class p = class_getSuperclass(c); p; p = class_getSuperclass(p))
                if (p == base) { isSub = YES; break; }
            if (!isSub) continue;
            int h = 0;
            h += ok_hook_sel(c, "boolForKey:",   (IMP)h_boolForKey,   &o_boolForKey);
            h += ok_hook_sel(c, "objectForKey:", (IMP)h_objectForKey, &o_objectForKey);
            h += ok_hook_sel(c, "stringForKey:", (IMP)h_stringForKey, &o_stringForKey);
            if (h) { subs++; oklog(@"L2: 子类 %s 单独挂钩 %d 个", class_getName(c), h); }
        }
        free(list);
    }
    g_ud_hooked = YES;
    oklog(@"L2: NSUserDefaults 挂钩 基类 %d 个 + 子类 %d 个；白名单键 = %s（无模糊匹配）",
          n, subs, OK_PRO_KEY);
    if (!o_boolForKey || !o_objectForKey || !o_stringForKey)
        oklog(@"L2: ⚠️ 部分原实现未取到 —— 对应键将放行给系统处理");
}

// ---------------------------------------------------------------- L3：Keychain 终身项预置
typedef const void *CFTypeRefC;
typedef const void *CFDictRefC;
typedef int OSStatusC;
static OSStatusC (*p_SecItemAdd)(CFDictRefC, CFTypeRefC *) = NULL;
static OSStatusC (*p_SecItemDelete)(CFDictRefC) = NULL;
static OSStatusC (*p_SecItemCopyMatching)(CFDictRefC, CFTypeRefC *) = NULL;

static void *ok_sec = NULL;
static void ok_seed_keychain(void) {
    ok_sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
    if (!ok_sec) { oklog(@"L3: Security.framework 打开失败，跳过"); return; }
    p_SecItemAdd          = (OSStatusC (*)(CFDictRefC, CFTypeRefC *))dlsym(ok_sec, "SecItemAdd");
    p_SecItemDelete       = (OSStatusC (*)(CFDictRefC))dlsym(ok_sec, "SecItemDelete");
    p_SecItemCopyMatching = (OSStatusC (*)(CFDictRefC, CFTypeRefC *))dlsym(ok_sec, "SecItemCopyMatching");
    oklog(@"L3: Security 符号 Add=%p Del=%p Copy=%p",
          (void *)p_SecItemAdd, (void *)p_SecItemDelete, (void *)p_SecItemCopyMatching);
    if (!p_SecItemAdd || !p_SecItemDelete) return;

    // 通过 dlsym 取 kSec* 常量指针
    CFTypeRefC *pClass   = (CFTypeRefC *)dlsym(ok_sec, "kSecClass");
    CFTypeRefC *pClassGP = (CFTypeRefC *)dlsym(ok_sec, "kSecClassGenericPassword");
    CFTypeRefC *pService = (CFTypeRefC *)dlsym(ok_sec, "kSecAttrService");
    CFTypeRefC *pAccount = (CFTypeRefC *)dlsym(ok_sec, "kSecAttrAccount");
    CFTypeRefC *pValue   = (CFTypeRefC *)dlsym(ok_sec, "kSecValueData");
    CFTypeRefC *pGroup   = (CFTypeRefC *)dlsym(ok_sec, "kSecAttrAccessGroup");
    CFTypeRefC *pAccess  = (CFTypeRefC *)dlsym(ok_sec, "kSecAttrAccessible");
    CFTypeRefC *pAccAFU  = (CFTypeRefC *)dlsym(ok_sec, "kSecAttrAccessibleAfterFirstUnlock");
    if (!pClass || !pClassGP || !pService || !pAccount || !pValue || !pAccess || !pAccAFU) {
        oklog(@"L3: kSec* 常量缺失，跳过 Keychain 预置");
        return;
    }

    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    q[(__bridge id)*pClass]   = (__bridge id)*pClassGP;
    q[(__bridge id)*pService] = ok_str(OK_KC_SERVICE);
    if (pGroup) q[(__bridge id)*pGroup] = ok_str(OK_APP_GROUP);
    q[(__bridge id)*pAccess]  = (__bridge id)*pAccAFU;

    NSMutableDictionary *a = [q mutableCopy];
    a[(__bridge id)*pAccount] = ok_str(OK_KC_ACCOUNT);
    a[(__bridge id)*pValue]   = [@"1" dataUsingEncoding:NSUTF8StringEncoding];

    p_SecItemDelete((__bridge CFDictRefC)a);
    OSStatusC st = p_SecItemAdd((__bridge CFDictRefC)a, NULL);
    oklog(@"L3: Keychain 预置 %s status=%d", OK_KC_ACCOUNT, (int)st);

    // 回读确认
    if (p_SecItemCopyMatching) {
        NSMutableDictionary *r = [q mutableCopy];
        r[(__bridge id)*pAccount] = ok_str(OK_KC_ACCOUNT);
        r[(__bridge id)dlsym(ok_sec, "kSecReturnData")] = @YES;
        r[(__bridge id)dlsym(ok_sec, "kSecMatchLimit")] =
            (__bridge id)dlsym(ok_sec, "kSecMatchLimitOne");
        CFTypeRefC out = NULL;
        OSStatusC s2 = p_SecItemCopyMatching((__bridge CFDictRefC)r, &out);
        NSString *v = @"(nil)";
        if (out) {
            NSData *d = (__bridge_transfer NSData *)out;
            v = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        }
        oklog(@"L3: 回读 status=%d value=%@", (int)s2, v ?: @"(nil)");
    }
}

// ---------------------------------------------------------------- App Group
static void ok_seed_group(void) {
    NSUserDefaults *g = [[NSUserDefaults alloc] initWithSuiteName:@OK_APP_GROUP];
    if (!g) { oklog(@"L2: AppGroup(%s) 不可用（可能缺 entitlement），已跳过", OK_APP_GROUP); return; }
    [g setBool:YES forKey:@OK_PRO_KEY];
    [g synchronize];
    id back = [g objectForKey:@OK_PRO_KEY];
    oklog(@"L2: AppGroup(%s) %s 写入，回读=%@", OK_APP_GROUP, OK_PRO_KEY, back ?: @"(nil)");
}

// ---------------------------------------------------------------- 延迟初始化（主线程、App 启动后）
static void ok_deferred(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"(nil)";
        oklog(@"=== VecOK 初始化 ===");
        oklog(@"bundle = %@  pid = %d", bid, getpid());

        ok_hook_ud();
        ok_swizzle_pro();
        ok_seed_keychain();
        ok_seed_group();

        oklog(@"=== 初始化完成（L1 交换 %d 个 / L2 白名单 1 键 / L3 Keychain）===", g_hookCount);
    }
}

// ---------------------------------------------------------------- ctor：只做最小动作
__attribute__((constructor)) static void ok_ctor(void) {
    // 官方规范：dyld 构造期绝不做重活（不碰 objc / UI / 文件系统高层 API），
    // 否则是"启动即闪退"的头号成因。这里只把自己的启动标记写进一个静态变量，
    // 然后异步派发到主队列，等 App 启动完成后再执行。
    static volatile int once = 0;
    if (__sync_lock_test_and_set(&once, 1)) return;

    dispatch_async(dispatch_get_main_queue(), ^{
        ok_deferred();
    });
}
