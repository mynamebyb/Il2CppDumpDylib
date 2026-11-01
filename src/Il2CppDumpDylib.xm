//
//  Il2CppDumpDylib.xm
//  手动触发：内存 dump global-metadata.dat + UnityFramework
//  产物写到 App Documents 目录，用 File Sharing 导出
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>

#pragma mark - 全局：记录 UnityFramework 模块位置

static uintptr_t g_unityBase = 0;
static uintptr_t g_unitySize = 0;

static void find_unity_image(const mach_header* hdr, intptr_t slide) {
    Dl_info info;
    if (dladdr(hdr, &info) == 0) return;
    NSString* path = [NSString stringWithUTF8String:info.dli_fname];
    if ([path containsString:@"UnityFramework"]) {
        g_unityBase = (uintptr_t)hdr + (uintptr_t)slide;
        const mach_header_64* h = (const mach_header_64*)g_unityBase;
        uintptr_t maxEnd = 0;
        const segment_command_64* cmd = (const segment_command_64*)((uintptr_t)h + sizeof(mach_header_64));
        for (uint32_t i = 0; i < h->ncmds; i++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                uintptr_t end = (uintptr_t)cmd->vmaddr + (uintptr_t)cmd->vmsize;
                if (end > maxEnd) maxEnd = end;
            }
            cmd = (const segment_command_64*)((uintptr_t)cmd + cmd->cmdsize);
        }
        g_unitySize = maxEnd - (uintptr_t)h;
        NSLog(@"[Dump] UnityFramework base=0x%lx size=0x%lx path=%@", (unsigned long)g_unityBase, (unsigned long)g_unitySize, path);
    }
}

static void enumerate_unity(void) {
    _dyld_register_func_for_add_image(find_unity_image);
}

#pragma mark - Dump: global-metadata.dat（扫内存找 magic）

static NSString* dump_metadata(void) {
    task_t task = mach_task_self();
    vm_address_t address = 0;
    vm_size_t size;
    struct vm_region_basic_info_64 info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object_name;

    while (vm_region_64(task, &address, &size, VM_REGION_BASIC_INFO_64,
                        (vm_region_info_t)&info, &count, &object_name) == KERN_SUCCESS) {
        if (size >= 0x100000) {
            const uint8_t* p = (const uint8_t*)address;
            uint32_t magic = 0;
            @try { magic = *(volatile uint32_t*)p; } @catch(NSException* e) {}
            if (magic == 0xFAB11BAF) {
                NSLog(@"[Dump] metadata magic @ %p", p);
                uint32_t ver = *(volatile uint32_t*)(p + 4);
                uint64_t maxEnd = 0;
                for (int off = 8; off < 0x250; off += 8) {
                    uint32_t o = *(volatile uint32_t*)(p + off);
                    uint32_t s = *(volatile uint32_t*)(p + off + 4);
                    if (o > 0 && o < 0x20000000 && s > 0 && s < 0x20000000) {
                        uint64_t e = (uint64_t)o + s;
                        if (e > maxEnd && e < 0x20000000) maxEnd = e;
                    }
                }
                if (maxEnd < 0x100000) maxEnd = 0x2000000;
                NSLog(@"[Dump] version=%u estSize=%llu", ver, (unsigned long long)maxEnd);

                NSMutableData* data = [NSMutableData dataWithLength:maxEnd];
                uint8_t* out = (uint8_t*)data.mutableBytes;
                uint64_t done = 0;
                for (uint64_t off = 0; off < maxEnd; off += 0x4000) {
                    vm_size_t chunkSize = (maxEnd - off < 0x4000) ? (maxEnd - off) : 0x4000;
                    vm_offset_t readBuf = 0;
                    mach_msg_type_number_t readCnt = 0;
                    kern_return_t kr = vm_read(task, (vm_address_t)(p + off), chunkSize, &readBuf, &readCnt);
                    if (kr == KERN_SUCCESS && readCnt > 0) {
                        memcpy(out + off, (void*)readBuf, readCnt);
                        vm_deallocate(task, readBuf, readCnt);
                        done += readCnt;
                    }
                }
                NSString* doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString* outFile = [doc stringByAppendingPathComponent:@"global-metadata.dat"];
                [data writeToFile:outFile atomically:NO];
                NSLog(@"[Dump] metadata written: %@ (%llu read)", outFile, (unsigned long long)done);
                return [NSString stringWithFormat:@"metadata ✅ %llu bytes", (unsigned long long)maxEnd];
            }
        }
        address += size;
    }
    return @"metadata ❌ 没找到 magic（等资源下完再点）";
}

#pragma mark - Dump: UnityFramework 模块内存

static NSString* dump_unity(void) {
    if (!g_unityBase || !g_unitySize) return @"UnityFramework ❌ 未找到模块";
    task_t task = mach_task_self();
    NSMutableData* data = [NSMutableData dataWithLength:g_unitySize];
    uint8_t* out = (uint8_t*)data.mutableBytes;
    uint64_t done = 0;
    for (uint64_t off = 0; off < g_unitySize; off += 0x4000) {
        vm_size_t chunkSize = (g_unitySize - off < 0x4000) ? (g_unitySize - off) : 0x4000;
        vm_offset_t readBuf = 0;
        mach_msg_type_number_t readCnt = 0;
        kern_return_t kr = vm_read(task, g_unityBase + off, chunkSize, &readBuf, &readCnt);
        if (kr == KERN_SUCCESS && readCnt > 0) {
            memcpy(out + off, (void*)readBuf, readCnt);
            vm_deallocate(task, readBuf, readCnt);
            done += readCnt;
        }
    }
    NSString* doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString* outFile = [doc stringByAppendingPathComponent:@"UnityFramework"];
    [data writeToFile:outFile atomically:NO];
    NSLog(@"[Dump] UnityFramework written: %@ (%llu read / %lu)", outFile, (unsigned long long)done, (unsigned long)g_unitySize);
    return [NSString stringWithFormat:@"UnityFramework ✅ %llu read / %lu", (unsigned long long)done, (unsigned long)g_unitySize];
}

#pragma mark - UI

@interface DumpButton : NSObject @end
@implementation DumpButton

+ (void)load {
    NSLog(@"[Dump] ✅ dylib loaded");
    enumerate_unity();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:nil usingBlock:^(NSNotification * _Nonnull n) {
            [self showButton];
        }];
    });
}

+ (void)showButton {
    UIWindowScene* scene = nil;
    for (UIWindowScene* s in UIApplication.sharedApplication.connectedScenes.allObjects) {
        if (s.activationState == UISceneActivationStateForegroundActive) { scene = s; break; }
    }
    if (!scene) return;

    UIWindow* w = [[UIWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    w.hidden = NO;

    UIButton* btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"DUMP" forState:UIControlStateNormal];
    btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    btn.frame = CGRectMake(16, 200, 60, 40);
    btn.layer.cornerRadius = 8;
    [btn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
    [w.rootViewController.view addSubview:btn];
}

+ (void)onDump {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Dump"
                                                                   message:@"开始 dump？确保游戏资源已下完"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString* r1 = dump_metadata();
            NSString* r2 = dump_unity();
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController* done = [UIAlertController alertControllerWithTitle:@"完成"
                                                                               message:[NSString stringWithFormat:@"%@\n%@\n\n文件在 Documents 目录，用 File Sharing 导出", r1, r2]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:done animated:YES completion:nil];
            });
        });
    }]];
    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

@end
