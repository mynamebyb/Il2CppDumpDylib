//
//  Il2CppDumpDylib.xm
//  手动触发：内存 dump global-metadata.dat + UnityFramework
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

#pragma mark - 全局

static uintptr_t g_unityBase = 0;
static uintptr_t g_unitySize = 0;

static uintptr_t safe_read_ptr(mach_port_t task, uintptr_t addr) {
    vm_offset_t buf = 0;
    mach_msg_type_number_t cnt = 0;
    kern_return_t kr = vm_read(task, addr, sizeof(uintptr_t), &buf, &cnt);
    if (kr != KERN_SUCCESS || cnt < sizeof(uintptr_t)) return 0;
    return (uintptr_t)buf;
}

static uint32_t safe_read_u32(mach_port_t task, uintptr_t addr) {
    vm_offset_t buf = 0;
    mach_msg_type_number_t cnt = 0;
    kern_return_t kr = vm_read(task, addr, sizeof(uint32_t), &buf, &cnt);
    if (kr != KERN_SUCCESS || cnt < sizeof(uint32_t)) return 0;
    return (uint32_t)buf;
}

// dyld 回调必须纯 C，不能用 NSString / ObjC
static void find_unity_image(const mach_header* hdr, intptr_t slide) {
    Dl_info info;
    if (dladdr(hdr, &info) == 0) return;
    const char* path = info.dli_fname ? info.dli_fname : "";
    if (!strstr(path, "UnityFramework")) return;

    g_unityBase = (uintptr_t)hdr + (uintptr_t)slide;

    // 遍历 load commands 算模块大小
    task_t task = mach_task_self();
    uint32_t ncmds = safe_read_u32(task, g_unityBase + 16); // mach_header_64.ncmds
    uintptr_t cmds_start = g_unityBase + sizeof(struct mach_header_64);
    uintptr_t maxEnd = 0;

    for (uint32_t i = 0; i < ncmds && i < 64; i++) {
        uint32_t cmd = safe_read_u32(task, cmds_start);
        uint32_t cmdsize = safe_read_u32(task, cmds_start + 4);
        if (cmdsize == 0 || cmdsize > 0x100000) break;
        if (cmd == 0x19) { // LC_SEGMENT_64
            uint64_t vmaddr = 0, vmsize = 0;
            vm_offset_t buf = 0;
            mach_msg_type_number_t cnt = 0;
            if (vm_read(task, cmds_start + 8, 16, &buf, &cnt) == KERN_SUCCESS) {
                memcpy(&vmaddr, (void*)buf, 8);
                memcpy(&vmsize, (void*)buf + 8, 8);
                vm_deallocate(task, buf, cnt);
            }
            uint64_t end = vmaddr + vmsize;
            if (end > maxEnd) maxEnd = end;
        }
        cmds_start += cmdsize;
    }
    g_unitySize = maxEnd - g_unityBase;
    NSLog(@"[Dump] UnityFramework base=0x%lx size=0x%lx", (unsigned long)g_unityBase, (unsigned long)g_unitySize);
}

#pragma mark - Dump metadata

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
            uint32_t magic = safe_read_u32(task, address);
            if (magic == 0xFAB11BAF) {
                NSLog(@"[Dump] metadata magic @ 0x%lx", (unsigned long)address);
                uint32_t ver = safe_read_u32(task, address + 4);

                // 估算大小：扫描 header 里的 offset+size 对
                uint64_t maxEnd = 0;
                for (int off = 8; off < 0x250; off += 8) {
                    uint32_t o = safe_read_u32(task, address + off);
                    uint32_t s = safe_read_u32(task, address + off + 4);
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
                    kern_return_t kr = vm_read(task, (vm_address_t)(address + off), chunkSize, &readBuf, &readCnt);
                    if (kr == KERN_SUCCESS && readCnt > 0) {
                        memcpy(out + off, (void*)readBuf, readCnt);
                        vm_deallocate(task, readBuf, readCnt);
                        done += readCnt;
                    }
                }
                NSString* doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString* outFile = [doc stringByAppendingPathComponent:@"global-metadata.dat"];
                [data writeToFile:outFile atomically:NO];
                NSLog(@"[Dump] metadata written: %llu read", (unsigned long long)done);
                return [NSString stringWithFormat:@"metadata ✅ %llu bytes", (unsigned long long)maxEnd];
            }
        }
        address += size;
    }
    return @"metadata ❌ 没找到 magic";
}

#pragma mark - Dump UnityFramework

static NSString* dump_unity(void) {
    if (!g_unityBase || !g_unitySize) return @"UnityFramework ❌ 未找到";
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
    NSLog(@"[Dump] UnityFramework written: %llu / %lu", (unsigned long long)done, (unsigned long)g_unitySize);
    return [NSString stringWithFormat:@"UnityFramework ✅ %llu / %lu", (unsigned long long)done, (unsigned long)g_unitySize];
}

#pragma mark - UI

static UIButton* g_btn = nil;

@interface DumpUI : NSObject @end
@implementation DumpUI

+ (void)load {
    NSLog(@"[Dump] dylib loaded");
    _dyld_register_func_for_add_image(find_unity_image);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil queue:nil usingBlock:^(NSNotification * _Nonnull n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showButton];
            });
        }];
    });
}

+ (void)showButton {
    @try {
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

        g_btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [g_btn setTitle:@"DUMP" forState:UIControlStateNormal];
        g_btn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.9];
        [g_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        g_btn.frame = CGRectMake(16, 300, 60, 40);
        g_btn.layer.cornerRadius = 8;
        [g_btn addTarget:self action:@selector(onDump) forControlEvents:UIControlEventTouchUpInside];
        [w.rootViewController.view addSubview:g_btn];
        NSLog(@"[Dump] button shown");
    } @catch (NSException *e) {
        NSLog(@"[Dump] showButton error: %@", e);
    }
}

+ (void)onDump {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Dump"
                                                                   message:@"开始？确保资源已下完"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"开始" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString* r1 = dump_metadata();
            NSString* r2 = dump_unity();
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController* done = [UIAlertController alertControllerWithTitle:@"完成"
                                                                               message:[NSString stringWithFormat:@"%@\n%@", r1, r2]
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:done animated:YES completion:nil];
            });
        });
    }]];
    [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

@end
