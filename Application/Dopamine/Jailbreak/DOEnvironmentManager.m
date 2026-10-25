//
//  EnvironmentManager.m
//  Dopamine
//
//  Created by Lars Fröder on 10.01.24.
//

#import "DOEnvironmentManager.h"
#import <CoreServices/LSApplicationProxy.h>
#import "UIImage+JPEG2000.h"

#import <sys/sysctl.h>
#import <sys/mount.h>
#import <sys/utsname.h>
#import <sys/stat.h>
#import <unistd.h>
#import <mach-o/dyld.h>
#import <libgrabkernel2/libgrabkernel2.h>
#import <libjailbreak/info.h>
#import <libjailbreak/codesign.h>
#import <libjailbreak/util.h>
#import <libjailbreak/display.h>
#import <libjailbreak/machine_info.h>
#import <libjailbreak/carboncopy.h>

#import <IOKit/IOKitLib.h>
#import "DOUIManager.h"
#import "DOExploitManager.h"
#import "DOPreferenceManager.h"
#import "NSData+Hex.h"
#import <LocalAuthentication/LocalAuthentication.h>

int reboot3(uint64_t flags, ...);
CFPropertyListRef MGCopyAnswer(CFStringRef);
extern char **environ;

@implementation DOEnvironmentManager

+ (instancetype)sharedManager
{
    static DOEnvironmentManager *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[DOEnvironmentManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _bootstrapNeedsMigration = NO;
        _bootstrapper = [[DOBootstrapper alloc] init];
        if ([self isJailbroken]) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jbclient_get_jbroot() ?: "");
        }
        else if ([self isInstalledThroughTrollStore]) {
            [self locateJailbreakRoot];
        }
    }
    return self;
}

- (NSString *)nightlyHash
{
#ifdef NIGHTLY
    return [NSString stringWithUTF8String:COMMIT_HASH];
#else
    return nil;
#endif
}

- (NSString *)appVersion
{
    return [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
}

- (NSString *)appVersionDisplayString
{
    NSString *nightlyHash = [self nightlyHash];
    if (nightlyHash) {
        return [NSString stringWithFormat:@"%@~%@", self.appVersion, [nightlyHash substringToIndex:6]];
    }
    else {
        return [self appVersion];
    }
}

- (NSString *)privatePrebootPath
{
    return @"/private/preboot";
}

- (NSString *)activePrebootPath
{
    NSString *bootManifestString = [NSString stringWithUTF8String:boot_manifest_hash()];
    return [[self privatePrebootPath] stringByAppendingPathComponent:bootManifestString];
}

/*
- (void)locateJailbreakRoot
{
    if (!gSystemInfo.jailbreakInfo.rootPath) {
        NSString *activePrebootPath = [self activePrebootPath];
        
        NSString *randomizedJailbreakPath;
        
        // First attempt at finding jailbreak root, look for Dopamine 2.x path
        for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
            if (subItem.length == 15 && [subItem hasPrefix:@"dopamine-"]) {
                randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                break;
            }
        }
        
        if (!randomizedJailbreakPath) {
            // Second attempt at finding jailbreak root, look for Dopamine 1.x path, but as other jailbreaks use it too, make sure it is Dopamine
            // Some other jailbreaks also commit the sin of creating .installed_dopamine, for these we try to filter them out by checking for their installed_ file
            // If we find this and are sure it's from Dopamine 1.x, rename it so all Dopamine 2.x users will have the same path
            for (NSString *subItem in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:activePrebootPath error:nil]) {
                if (subItem.length == 9 && [subItem hasPrefix:@"jb-"]) {
                    NSString *candidateLegacyPath = [activePrebootPath stringByAppendingPathComponent:subItem];
                    
                    BOOL installedDopamine = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_dopamine"]];
                    
                    if (installedDopamine) {
                        // Hopefully all other jailbreaks that use jb-<UUID>?
                        // These checks exist because of dumb users (and jailbreak developers) creating .installed_dopamine on jailbreaks that are NOT dopamine...
                        BOOL installedNekoJB = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.installed_nekojb"]];
                        BOOL installedDefinitelyNotAGoodName = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.xia0o0o0o_jb_installed"]];
                        BOOL installedPalera1n = [[NSFileManager defaultManager] fileExistsAtPath:[candidateLegacyPath stringByAppendingPathComponent:@"procursus/.palecursus_strapped"]];
                        if (installedNekoJB || installedPalera1n || installedDefinitelyNotAGoodName) {
                            continue;
                        }
                        
                        randomizedJailbreakPath = candidateLegacyPath;
                        _bootstrapNeedsMigration = YES;
                        break;
                    }
                }
            }
        }
        
        if (randomizedJailbreakPath) {
            NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                // This attribute serves as the primary source of what the root path is
                // Anything else in the jailbreak will get it from here
                gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.fileSystemRepresentation);
            }
        }
    }
}

- (NSError *)ensureJailbreakRootExists
{
    NSError *error = nil;

    [self locateJailbreakRoot];

    // DOPACLEAN logic to move a corrupted dopamine directory to a different path to at least make jailbreaking work again
    // if (gSystemInfo.jailbreakInfo.rootPath) {
    //     NSString *randomizedJailbreakPath = [NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath].stringByDeletingLastPathComponent;
    //     NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    //     NSUInteger stringLen = 6;
    //     NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
    //     for (NSUInteger i = 0; i < stringLen; i++) {
    //         NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
    //         unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
    //         [randomString appendFormat:@"%C", randomCharacter];
    //     }
        
    //     NSString *activePrebootPath = [self activePrebootPath];
    //     NSString *orphanedName = [NSString stringWithFormat:@"orphaned-%@", randomString];
    //     NSString *orphanedPath = [activePrebootPath stringByAppendingPathComponent:orphanedName];
    //     [[NSFileManager defaultManager] moveItemAtPath:randomizedJailbreakPath toPath:orphanedPath error:nil];
    // }

    // return [NSError errorWithDomain:@"Cleaned" code:1 userInfo:nil];

    if (!gSystemInfo.jailbreakInfo.rootPath || _bootstrapNeedsMigration) {
        [_bootstrapper ensurePrivatePrebootIsWritable];

        NSString *activePrebootPath = [self activePrebootPath];

        NSString *characterSet = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        NSUInteger stringLen = 6;
        NSMutableString *randomString = [NSMutableString stringWithCapacity:stringLen];
        for (NSUInteger i = 0; i < stringLen; i++) {
            NSUInteger randomIndex = arc4random_uniform((uint32_t)[characterSet length]);
            unichar randomCharacter = [characterSet characterAtIndex:randomIndex];
            [randomString appendFormat:@"%C", randomCharacter];
        }
        
        NSString *randomJailbreakFolderName = [NSString stringWithFormat:@"dopamine-%@", randomString];
        NSString *randomizedJailbreakPath = [activePrebootPath stringByAppendingPathComponent:randomJailbreakFolderName];
        NSString *jailbreakRootPath = [randomizedJailbreakPath stringByAppendingPathComponent:@"procursus"];
        
        if (_bootstrapNeedsMigration) {
            NSString *oldRandomizedJailbreakPath = [[NSString stringWithUTF8String:gSystemInfo.jailbreakInfo.rootPath] stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] moveItemAtPath:oldRandomizedJailbreakPath toPath:randomizedJailbreakPath error:&error];
        }
        else {
            if (![[NSFileManager defaultManager] fileExistsAtPath:jailbreakRootPath]) {
                [[NSFileManager defaultManager] createDirectoryAtPath:jailbreakRootPath withIntermediateDirectories:YES attributes:nil error:&error];
            }
        }
        
        if (!error) {
            gSystemInfo.jailbreakInfo.rootPath = strdup(jailbreakRootPath.UTF8String);
        }
    }
    
    return error;
}
*/

- (BOOL)isArm64e
{
    cpu_subtype_t cpusubtype = 0;
    size_t len = sizeof(cpusubtype);
    if (sysctlbyname("hw.cpusubtype", &cpusubtype, &len, NULL, 0) == -1) return NO;
    return (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E;
}

- (BOOL)isSPTM
{
    if (@available(iOS 17.0, *)) {
        io_registry_entry_t memory_map = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen/memory-map");
        if (memory_map == IO_OBJECT_NULL)   return NO;

        CFArrayRef keys = (CFArrayRef)IORegistryEntryCreateCFProperty(memory_map, CFSTR(kIORegistryEntryPropertyKeysKey), kCFAllocatorDefault, 0);
        IOObjectRelease(memory_map);
        if (!keys)  return NO;

        CFRange range = CFRangeMake(0, CFArrayGetCount(keys));

        bool isSPTM = CFArrayContainsValue(keys, range, CFSTR("SPTM")) && CFArrayContainsValue(keys, range, CFSTR("TXM"));
        CFRelease(keys);

        return isSPTM;
    }
    return false;
}

- (NSString *)versionSupportString
{
    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    
    if ([self isArm64e]) {
        if (cpuFamily == CPUFAMILY_ARM_VORTEX_TEMPEST || cpuFamily == CPUFAMILY_ARM_LIGHTNING_THUNDER) {
            return @"iOS 15.0 - 18.7.1, 26.0 - 26.0.1 (A12/A13, PPL)";
        }
        else if (![self isSPTM]) {
            return @"iOS 15.0 - 17.3.1 (PPL)";
        }
        else {
            return @"iOS 17.0 - 17.3.1 (SPTM)";
        }
    }
    else {
        return @"iOS 15.0 - 18.7.1 (arm64)";
    }
}

- (BOOL)isInstalledThroughTrollStore
{
    static BOOL trollstoreInstallation = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString* trollStoreMarkerPath = [[[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_TrollStore"];
        trollstoreInstallation = [[NSFileManager defaultManager] fileExistsAtPath:trollStoreMarkerPath];
    });
    return trollstoreInstallation;
}

- (void)updateJailbreakState
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        char *jbVersionC = NULL;
        _isJailbroken = jbclient_dopamine_is_jailbroken(&jbVersionC);
        if (jbVersionC) {
            _jailbrokenVersion = [NSString stringWithUTF8String:jbVersionC];
            free(jbVersionC);
        }
    });
}

- (BOOL)isJailbroken
{
/************** roothide specific ***********/
    if(!jbclient_roothide_jailbroken())
        return NO;
/************** roothide specific ********/

    [self updateJailbreakState];
    return _isJailbroken;
}

- (void)setJailbroken:(BOOL)jailbroken withVersion:(NSString *)version
{
    _isJailbroken = jailbroken;
    if (_isJailbroken) _jailbrokenVersion = version;
}

- (BOOL)isJailbrokenWithOtherJailbreak
{
    if (![self isJailbroken]) {
        uint32_t csFlags = 0;
        csops(getpid(), CS_OPS_STATUS, &csFlags, sizeof(csFlags));
        
        // Palera1n
        if (csFlags & CS_PLATFORM_BINARY) return YES;
        
        // Older Dopamine build
        if (!access("/usr/lib/systemhook.dylib", F_OK)) return YES;
    }
    return NO;
}

- (NSString *)jailbrokenVersion
{
    [self updateJailbreakState];
    if (!_isJailbroken) return nil;
    return _jailbrokenVersion;
}

- (NSString *)jailbrokenVersionRootHide
{
    NSString *versionFile = JBROOT_PATH(@"/basebin/.version-roothide");
    if(!versionFile) {
        return nil;
    }
    return [NSString stringWithContentsOfFile:versionFile encoding:NSUTF8StringEncoding error:nil];
}

- (NSString *)systemVersion
{
    return (__bridge NSString *)MGCopyAnswer((__bridge CFStringRef)@"ProductVersion");
}

- (BOOL)isBootstrapped
{
    return (BOOL)jbinfo(rootPath);
}

- (void)runUnsandboxed:(void (^)(void))unsandboxBlock
{
    if ([self isInstalledThroughTrollStore]) {
        unsandboxBlock();
    }
    else if ([self isJailbroken]) {
        uint64_t labelBackup = 0;
        jbclient_root_set_mac_label(1, -1, &labelBackup);
        unsandboxBlock();
        jbclient_root_set_mac_label(1, labelBackup, NULL);
    }
    else {
        // Hope that we are already unsandboxed
        unsandboxBlock();
    }
}

- (void)runAsRoot:(void (^)(void))rootBlock
{
    uint32_t orgUser = geteuid();
    uint32_t orgGroup = getegid();
    
    if (orgUser == 0 && orgGroup == 0) {
        rootBlock();
        return;
    }

    if (self.isJailbroken) {
        if (jbclient_dopamine_get_root() == 0) {
            rootBlock();
            jbclient_dopamine_drop_root();
        }
    }
}

- (int)spawnJbctlAsRootWithArgs:(NSArray *)args
{
    bool needsLegacySolution = false;
    if (self.jailbrokenVersion) {
        needsLegacySolution = (strcmp(self.jailbrokenVersion.UTF8String, "3.0.5") < 0);
    }

    char **argBuf = malloc((args.count + 4) * sizeof(char *));
    argBuf[0] = strdup(JBROOT_PATH("/basebin/jbctl"));
    int i = 1;
    for (NSString *arg in args) {
        argBuf[i++] = strdup(arg.UTF8String);
    }

    if (!needsLegacySolution) {
        argBuf[i++] = strdup("--waitfor");
        argBuf[i++] = strdup("3");
    }
    argBuf[i++] = NULL;
    
    posix_spawn_file_actions_t act = NULL;
	posix_spawn_file_actions_init(&act);
    posix_spawnattr_t attr = NULL;
    posix_spawnattr_init(&attr);
     
    int waitPipe[2];
    
    if (!needsLegacySolution) {
        pipe(waitPipe);
        posix_spawn_file_actions_adddup2(&act, waitPipe[0], 3);
    }
    else {
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_START_SUSPENDED);
    }

    __block int pid = 0;
    __block int r = -1;

    [self runAsRoot:^{
        [self runUnsandboxed:^{
            r = posix_spawn(&pid, argBuf[0], &act, &attr, (char *const *)argBuf, (char *const *)environ);
            if (needsLegacySolution) {
                // Legacy solution is a gamble, which is why it was removed and superseeded by --waitfor
                // But if jailbroken with <3.0.5, jbctl doesn't support --waitfor yet
                kill(pid, SIGCONT);
            }
        }];
        // We *NEED* to leave this block on iOS 17+ to avoid a panic, --waitfor ensures this always happens
    }];

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&act);
    for (int y = 0; y < i; y++) {
        free(argBuf[y]);
    }
    free(argBuf);

    if (!needsLegacySolution) {
        if (r == 0) {
            // We left the root/unsandbox block, now resume jbctl by writing to pipe
            char w = 'w';
            write(waitPipe[1], &w, sizeof(w));
        }

        close(waitPipe[0]);
        close(waitPipe[1]);
    }

    return cmd_wait_for_exit(pid);
}

- (int)runTrollStoreAction:(NSString *)action
{
    if (![self isInstalledThroughTrollStore]) return -1;
    
    uint32_t selfPathSize = PATH_MAX;
    char selfPath[selfPathSize];
    _NSGetExecutablePath(selfPath, &selfPathSize);
    return exec_cmd_root(selfPath, "trollstore", action.UTF8String, NULL);
}

- (void)respring
{
    [self spawnJbctlAsRootWithArgs:@[@"respring"]];
}

- (void)rebootUserspace
{
    [self spawnJbctlAsRootWithArgs:@[@"reboot_userspace"]];
}

- (void)rebuildIconCache
{
    [self spawnJbctlAsRootWithArgs:@[@"rebuild_icon_cache"]];
}

- (void)refreshJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-a", NULL);
        }];
    }];
}

- (void)unregisterJailbreakApps
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSArray *jailbreakApps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:JBROOT_PATH(@"/Applications") error:nil];
            if (jailbreakApps.count) {
                for (NSString *jailbreakApp in jailbreakApps) {
                    NSString *jailbreakAppPath = [JBROOT_PATH(@"/Applications") stringByAppendingPathComponent:jailbreakApp];
                    exec_cmd(JBROOT_PATH("/usr/bin/uicache"), "-u", jailbreakAppPath.fileSystemRepresentation, NULL);
                }
            }
        }];
    }];
}

- (void)reboot
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            reboot3(0x8000000000000000, 0);
        }];
    }];
}


- (void)changeMobilePassword:(NSString *)newPassword
{
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *dashCommand = [NSString stringWithFormat:@"printf \"%%s\\n\" \"%@\" | %@ usermod 501 -h 0", newPassword, JBROOT_PATH(@"/usr/sbin/pw")];
            exec_cmd(JBROOT_PATH("/usr/bin/dash"), "-c", dashCommand.UTF8String, NULL);
        }];
    }];
}

- (NSError*)updateEnvironment
{
    NSString *newBasebinTarPath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"basebin.tar"];
    int result = jbclient_platform_stage_jailbreak_update(newBasebinTarPath.fileSystemRepresentation);
    if (result == 0) {
        [self rebootUserspace];
        return nil;
    }
    return [NSError errorWithDomain:@"Dopamine" code:result userInfo:nil];
}

- (void)updateJailbreakFromTIPA:(NSString *)tipaPath
{
    [self spawnJbctlAsRootWithArgs:@[@"update", @"tipa", tipaPath]];
}

- (BOOL)isTweakInjectionEnabled
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:JBROOT_PATH(@"/basebin/.safe_mode")];
}

- (void)setTweakInjectionEnabled:(BOOL)enabled
{
    NSString *safeModePath = JBROOT_PATH(@"/basebin/.safe_mode");
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                if (enabled) {
                    [[NSFileManager defaultManager] removeItemAtPath:safeModePath error:nil];
                }
                else {
                    [[NSData data] writeToFile:safeModePath atomically:YES];
                }
/*************************** roothide specific *******************/
                setBasebinDependency(enabled);
/*************************** roothide specific *******************/
            }];
        }];
    }
}

- (BOOL)isIDownloadEnabled
{
    __block BOOL isEnabled = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *disabledDict = [NSDictionary dictionaryWithContentsOfFile:@"/var/db/com.apple.xpc.launchd/disabled.plist"];
            NSNumber *idownloaddDisabledNum = disabledDict[@"com.opa334.Dopamine.idownloadd"];
            if (idownloaddDisabledNum) {
                isEnabled = ![idownloaddDisabledNum boolValue];
            }
            else {
                isEnabled = NO;
            }
        }];
    }];
    return isEnabled;
}

- (void)setIDownloadEnabled:(BOOL)enabled needsUnsandbox:(BOOL)needsUnsandbox
{
    void (^updateBlock)(void) = ^{
        if (enabled) {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "enable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
        else {
            exec_cmd_trusted(JBROOT_PATH("/usr/bin/launchctl"), "disable", "system/com.opa334.Dopamine.idownloadd", NULL);
        }
    };

    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
}

- (void)setIDownloadLoaded:(BOOL)loaded needsUnsandbox:(BOOL)needsUnsandbox
{
    if (loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
    
    void (^updateBlock)(void) = ^{
        if (loaded) {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "load", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
        else {
            exec_cmd(JBROOT_PATH("/usr/bin/launchctl"), "unload", JBROOT_PATH("/basebin/LaunchDaemons/com.opa334.Dopamine.idownloadd.plist"), NULL);
        }
    };
    
    if (needsUnsandbox) {
        [self runAsRoot:^{
            [self runUnsandboxed:updateBlock];
        }];
    }
    else {
        updateBlock();
    }
    
    if (!loaded) {
        [self setIDownloadEnabled:loaded needsUnsandbox:needsUnsandbox];
    }
}

/*
- (BOOL)isFakelibMounted
{
    struct statfs fsb;
    if (statfs("/usr/lib", &fsb) != 0) return NO;
    return strcmp(fsb.f_mntonname, "/usr/lib") == 0;
}

- (int)setFakelibMounted:(BOOL)mounted
{
    int r = 0;
    if (mounted != [self isFakelibMounted]) {
        NSString *arg = mounted ? @"mount" : @"unmount";
        r = [self spawnJbctlAsRootWithArgs:@[@"internal", @"fakelib", arg]];
    }
    return r;
}

- (int)setPrivatePrebootProtected:(BOOL)protected
{
    NSString *arg = protected ? @"activate" : @"deactivate";
    return [self spawnJbctlAsRootWithArgs:@[@"internal", @"protection", arg]];
}

- (BOOL)isJailbreakHidden
{
    return ![[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb"];
}

- (void)setJailbreakHidden:(BOOL)hidden
{
    if (hidden && ![self isJailbroken] && geteuid() != 0) {
        [self runTrollStoreAction:@"hide-jailbreak"];
        return;
    }
    
    void (^actionBlock)(void) = ^{
        BOOL alreadyHidden = [self isJailbreakHidden];
        if (hidden != alreadyHidden) {
            if (hidden) {
                if ([self isJailbroken]) {
                    [self unregisterJailbreakApps];
                    [self setPrivatePrebootProtected:NO];
                    [self setFakelibMounted:NO];
                    jbclient_platform_set_systemwide_domain_enabled(false);
                }
                [[NSFileManager defaultManager] removeItemAtPath:@"/var/jb" error:nil];
            }
            else {
                [[NSFileManager defaultManager] createSymbolicLinkAtPath:@"/var/jb" withDestinationPath:JBROOT_PATH(@"/") error:nil];
                if ([self isJailbroken]) {
                    jbclient_platform_set_systemwide_domain_enabled(true);
                    [self setFakelibMounted:YES];
                    [self setPrivatePrebootProtected:YES];
                    [self refreshJailbreakApps];
                }
            }
        }
    };
    
    if ([self isJailbroken]) {
        [self runAsRoot:^{
            [self runUnsandboxed:actionBlock];
        }];
    }
    else {
        actionBlock();
    }
}
*/

- (NSString *)accessibleKernelPath
{
    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *kernelcachePath = [[self activePrebootPath] stringByAppendingPathComponent:@"System/Library/Caches/com.apple.kernelcaches/kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            return kernelcachePath;
        }
        return @"/System/Library/Caches/com.apple.kernelcaches/kernelcache";
    }
    else {
        NSString *kernelInApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"kernelcache"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:kernelInApp]) {
            return kernelInApp;
        }
        
        [[DOUIManager sharedInstance] sendLog:@"Downloading Kernel" debug:NO];
        NSString *kernelcachePath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kernelcache"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:kernelcachePath]) {
            if (grab_images([NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]) == false) return nil;
        }
        return kernelcachePath;
    }
}

- (NSString *)accessibleSPTMPath
{
    NSString *sptmInAppPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"sptm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInAppPath]) {
        return sptmInAppPath;
    }
    
    NSString *sptmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sptm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInDocsPath]) {
        return sptmInDocsPath;
    }
    
    sptmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/sptm.im4p"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:sptmInDocsPath]) {
        return sptmInDocsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *sptmPath = [[self activePrebootPath] stringByAppendingPathComponent:@"/usr/standalone/firmware/FUD/Ap,SecurePageTableMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:sptmPath]) {
            return sptmPath;
        }
    }

    return nil;
}

- (NSString *)accessibleTXMPath
{
    NSString *txmInAppPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"txm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInAppPath]) {
        return txmInAppPath;
    }
    
    NSString *txmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/txm.img4"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInDocsPath]) {
        return txmInDocsPath;
    }
    
    txmInDocsPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/txm.im4p"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:txmInDocsPath]) {
        return txmInDocsPath;
    }

    if ([self isInstalledThroughTrollStore] || getuid() == 0) {
        NSString *txmPath = [[self activePrebootPath] stringByAppendingPathComponent:@"/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:txmPath]) {
            return txmPath;
        }
    }

    return nil;
}


- (BOOL)isPACBypassRequired
{
    if (![self isArm64e]) return NO;
    
    if (@available(iOS 15.2, *)) {
        return NO;
    }
    return YES;
}

- (BOOL)isPPLBypassRequired
{
    return [self isArm64e];
}

- (BOOL)isSupported
{
    //cpu_subtype_t cpuFamily = 0;
    //size_t cpuFamilySize = sizeof(cpuFamily);
    //sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);
    //if (cpuFamily == CPUFAMILY_ARM_TYPHOON) return false; // A8X is unsupported for now (due to 4k page size)
    
    DOExploitManager *exploitManager = [DOExploitManager sharedManager];
    if ([exploitManager availableExploitsForType:EXPLOIT_TYPE_KERNEL].count) {
        if (![self isPACBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PAC].count) {
            if (![self isPPLBypassRequired] || [exploitManager availableExploitsForType:EXPLOIT_TYPE_PPL].count) {
                return true;
            }
        }
    }
    
    return false;
}

- (BOOL)deviceSupportsFaceID
{
    if (![LAContext class]) return NO;

    LAContext *myContext = [[LAContext alloc] init];
    NSError *authError = nil;
    if (![myContext canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&authError]) {
        NSLog(@"%@", [authError localizedDescription]);
        return NO;
    }

    return myContext.biometryType == LABiometryTypeFaceID;
}

- (BOOL)deviceSupportsLandscapeBootLogo
{
    struct utsname u;
    uname(&u);
    const char *ipadString = "iPad";

    bool isPad = strncmp(u.machine, ipadString, strlen(ipadString)) == 0;
    return isPad && [self deviceSupportsFaceID];
}

- (NSError *)prepareBootstrap
{
    __block NSError *errOut;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [_bootstrapper prepareBootstrapWithCompletion:^(NSError *error) {
        errOut = error;
        dispatch_semaphore_signal(sema);
    }];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    return errOut;
}

- (NSError *)finalizeBootstrap
{
    return [_bootstrapper finalizeBootstrap];
}

- (NSError *)deleteBootstrap
{
    if (![self isJailbroken] && getuid() != 0) {
        int r = [self runTrollStoreAction:@"delete-bootstrap"];
        if (r != 0) {
            // TODO: maybe handle error
        }
        return nil;
    }
    else if ([self isJailbroken]) {
        __block NSError *error;
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                error = [self->_bootstrapper deleteBootstrap];
            }];
        }];
        return error;
    }
    else {
        // Let's hope for the best
        return [_bootstrapper deleteBootstrap];
    }
}

- (NSError *)reinstallPackageManagers
{
    __block NSError *error;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            error = [self->_bootstrapper installPackageManagers];
        }];
    }];
    return error;
}

- (NSError *)updateBootLogo
{
    const char *bootLogoPath = JBROOT_PATH("/basebin/bootlogo.jp2");
    if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"bootlogoEnabled" fallback:YES]) {
        UIImage *bootLogoImage;

        if ([[DOPreferenceManager sharedManager] boolPreferenceValueForKey:@"customBootlogoEnabled" fallback:NO]) {
            bootLogoImage = [NSClassFromString(@"UIImage") imageWithContentsOfFile:[DOUIManager sharedInstance].bootlogoPath];
        }

        if (!bootLogoImage) {
            bootLogoImage = [[DOUIManager sharedInstance] renderBootLogo];
        }

        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
                [[bootLogoImage jp2DataWithCompressionQuality:0.9] writeToFile:[NSString stringWithUTF8String:bootLogoPath] atomically:NO];
            }];
        }];

        return nil;
    }
    else {
        [self runAsRoot:^{
            [self runUnsandboxed:^{
                unlink(bootLogoPath);
            }];
        }];
        return nil;
    }
}


// --- ported from RC7 helpers ---

static NSString *DOCanonicalApplicationPath(NSString *path)
{
    if (!path.length) return nil;
    return [[path stringByResolvingSymlinksInPath] stringByStandardizingPath];
}

static NSString *DORegisteredApplicationPath(NSString *bundleIdentifier)
{
    if (!bundleIdentifier.length) return nil;

    LSApplicationProxy *appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleIdentifier];
    if (!appProxy.installed || !appProxy.bundleURL.path.length) return nil;
    return DOCanonicalApplicationPath(appProxy.bundleURL.path);
}

typedef NS_ENUM(NSUInteger, DOJailbreakAppRegistrationState) {
    DOJailbreakAppRegistrationStateMissing,
    DOJailbreakAppRegistrationStateMatches,
    DOJailbreakAppRegistrationStateStale,
    DOJailbreakAppRegistrationStateConflict,
};

static DOJailbreakAppRegistrationState DOJailbreakAppRegistrationStateForPath(NSString *bundleIdentifier, NSString *expectedPath, NSString **registeredPathOut)
{
    NSString *registeredPath = DORegisteredApplicationPath(bundleIdentifier);
    if (registeredPathOut) *registeredPathOut = registeredPath;

    if (!registeredPath) return DOJailbreakAppRegistrationStateMissing;
    if ([registeredPath isEqualToString:DOCanonicalApplicationPath(expectedPath)]) return DOJailbreakAppRegistrationStateMatches;
    if (![[NSFileManager defaultManager] fileExistsAtPath:registeredPath]) return DOJailbreakAppRegistrationStateStale;
    return DOJailbreakAppRegistrationStateConflict;
}

static NSError *DOJailbreakAppRegistrationConflictError(NSString *bundleIdentifier, NSString *expectedPath, NSString *registeredPath)
{
    return [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                               code:EEXIST
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Refusing to replace an existing app registration for %@. Expected %@, but LaunchServices is registered to %@.", bundleIdentifier, expectedPath, registeredPath]}];
}

static NSError *DOJailbreakAppUserConflictError(NSString *bundleIdentifier, NSString *expectedPath, NSString *userAppPath)
{
    return [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                               code:EEXIST
                           userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Refusing to repair %@ at %@ because a user application with the same bundle identifier exists at %@.", bundleIdentifier, expectedPath, userAppPath]}];
}

static NSString *DOUserApplicationPathForBundleIdentifier(NSString *bundleIdentifier)
{
    if (!bundleIdentifier.length) return nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *userAppsPath = @"/var/containers/Bundle/Application";
    for (NSString *appUUID in [fileManager contentsOfDirectoryAtPath:userAppsPath error:nil]) {
        NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
        for (NSString *appCandidate in [fileManager contentsOfDirectoryAtPath:UUIDPath error:nil]) {
            if (![appCandidate.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *userAppPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
            NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[userAppPath stringByAppendingPathComponent:@"Info.plist"]];
            if ([infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) {
                return DOCanonicalApplicationPath(userAppPath);
            }
        }
    }
    return nil;
}


// --- ported from RC7 ---
static NSDictionary<NSString *, id> *DOJailbreakAppHealthEntry(NSString *displayName,
                                                                  NSString *bundleIdentifier,
                                                                  NSString *applicationPath,
                                                                  NSString *stateName,
                                                                  BOOL healthy,
                                                                  BOOL repairable,
                                                                  NSString *detail)
{
    NSMutableDictionary<NSString *, id> *entry = [@{
        @"DisplayName" : displayName ?: bundleIdentifier ?: @"Jailbreak App",
        @"BundleIdentifier" : bundleIdentifier ?: @"",
        @"StateName" : stateName ?: @"Unknown",
        @"Healthy" : @(healthy),
        @"Repairable" : @(repairable),
    } mutableCopy];
    if (applicationPath.length) entry[@"ApplicationPath"] = DOCanonicalApplicationPath(applicationPath);
    if (detail.length) entry[@"Detail"] = detail;
    return entry.copy;
}

- (NSArray<NSDictionary<NSString *, id> *> *)jailbreakAppHealthReport
{
    __block NSMutableArray<NSDictionary<NSString *, id> *> *healthReport = [NSMutableArray array];

    [self runUnsandboxed:^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *applicationsPath = JBROOT_PATH(@"/Applications");
        NSError *directoryError = nil;
        NSArray<NSString *> *applicationNames = [fileManager contentsOfDirectoryAtPath:applicationsPath error:&directoryError];
        if (!applicationNames) {
            [healthReport addObject:DOJailbreakAppHealthEntry(@"Jailbreak Apps", nil, applicationsPath,
                                                              @"Inspection Failed", NO, NO,
                                                              directoryError.localizedDescription ?: @"Unable to enumerate jailbreak applications.")];
            return;
        }

        NSMutableArray<NSDictionary<NSString *, NSString *> *> *applications = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSNumber *> *identifierCounts = [NSMutableDictionary dictionary];
        for (NSString *applicationName in applicationNames) {
            if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
            NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
            NSString *displayName = infoDictionary[@"CFBundleDisplayName"] ?: infoDictionary[@"CFBundleName"] ?: applicationName.stringByDeletingPathExtension;
            [applications addObject:@{
                @"DisplayName" : displayName ?: @"Jailbreak App",
                @"BundleIdentifier" : bundleIdentifier ?: @"",
                @"ApplicationPath" : applicationPath,
            }];
            if (bundleIdentifier.length) {
                identifierCounts[bundleIdentifier] = @([identifierCounts[bundleIdentifier] unsignedIntegerValue] + 1);
            }
        }

        // Mirror repairJailbreakApps' physical duplicate-app protection, but build
        // the lookup once because this detector may inspect several jailbreak apps.
        NSMutableDictionary<NSString *, NSString *> *userApplicationPathsByIdentifier = [NSMutableDictionary dictionary];
        NSSet<NSString *> *jailbreakIdentifiers = [NSSet setWithArray:identifierCounts.allKeys];
        NSString *userAppsPath = @"/var/containers/Bundle/Application";
        for (NSString *appUUID in [fileManager contentsOfDirectoryAtPath:userAppsPath error:nil]) {
            NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
            for (NSString *appCandidate in [fileManager contentsOfDirectoryAtPath:UUIDPath error:nil]) {
                if (![appCandidate.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                NSString *userAppPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
                NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[userAppPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
                if (bundleIdentifier.length && [jailbreakIdentifiers containsObject:bundleIdentifier] && !userApplicationPathsByIdentifier[bundleIdentifier]) {
                    userApplicationPathsByIdentifier[bundleIdentifier] = DOCanonicalApplicationPath(userAppPath);
                }
            }
        }

        for (NSDictionary<NSString *, NSString *> *application in applications) {
            NSString *displayName = application[@"DisplayName"];
            NSString *bundleIdentifier = application[@"BundleIdentifier"];
            NSString *applicationPath = application[@"ApplicationPath"];

            if (!bundleIdentifier.length) {
                [healthReport addObject:DOJailbreakAppHealthEntry(displayName, nil, applicationPath,
                                                                  @"Bundle Invalid", NO, NO,
                                                                  @"The application is missing CFBundleIdentifier.")];
                continue;
            }
            if ([identifierCounts[bundleIdentifier] unsignedIntegerValue] > 1) {
                [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                  @"Bundle Invalid", NO, NO,
                                                                  [NSString stringWithFormat:@"Multiple jailbreak applications use the bundle identifier %@.", bundleIdentifier])];
                continue;
            }

            NSString *userAppPath = userApplicationPathsByIdentifier[bundleIdentifier];
            if (userAppPath.length) {
                [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                  @"Registration Conflict", NO, NO,
                                                                  [NSString stringWithFormat:@"A user application with the same bundle identifier exists at %@.", userAppPath])];
                continue;
            }

            NSString *registeredPath = nil;
            DOJailbreakAppRegistrationState registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
            switch (registrationState) {
                case DOJailbreakAppRegistrationStateMatches:
                    [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                      @"Healthy", YES, NO, nil)];
                    break;
                case DOJailbreakAppRegistrationStateMissing:
                    [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                      @"Registration Missing", NO, YES, nil)];
                    break;
                case DOJailbreakAppRegistrationStateStale:
                    [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                      @"Registration Stale", NO, YES,
                                                                      registeredPath.length ? [NSString stringWithFormat:@"LaunchServices still references %@.", registeredPath] : nil)];
                    break;
                case DOJailbreakAppRegistrationStateConflict:
                    [healthReport addObject:DOJailbreakAppHealthEntry(displayName, bundleIdentifier, applicationPath,
                                                                      @"Registration Conflict", NO, NO,
                                                                      registeredPath.length ? [NSString stringWithFormat:@"LaunchServices is registered to the live path %@.", registeredPath] : nil)];
                    break;
            }
        }
    }];

    return healthReport.copy;
}

- (NSError *)repairJailbreakApps
{
    __block NSError *repairError = nil;
    __block BOOL repairAttempted = NO;

    [self runAsRoot:^{
        repairAttempted = YES;
        [self runUnsandboxed:^{
            const char *uicachePath = JBROOT_PATH("/usr/bin/uicache");
            if (access(uicachePath, X_OK) != 0) {
                int errorCode = errno ? errno : ENOENT;
                repairError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errorCode userInfo:nil];
                return;
            }

            NSString *applicationsPath = JBROOT_PATH(@"/Applications");
            NSError *directoryError = nil;
            NSArray<NSString *> *applicationNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:applicationsPath error:&directoryError];
            if (!applicationNames) {
                repairError = directoryError ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil];
                return;
            }

            // Build and validate the complete jailbreak-app set before changing LaunchServices.
            NSMutableDictionary<NSString *, NSString *> *applicationsByIdentifier = [NSMutableDictionary dictionary];
            for (NSString *applicationName in applicationNames) {
                if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

                NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
                NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
                if (!bundleIdentifier.length) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:EINVAL
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Jailbreak app is missing CFBundleIdentifier: %@", applicationPath]}];
                    return;
                }

                if (applicationsByIdentifier[bundleIdentifier]) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:EEXIST
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Duplicate jailbreak app bundle identifier: %@", bundleIdentifier]}];
                    return;
                }
                applicationsByIdentifier[bundleIdentifier] = applicationPath;
            }

            // Mirror DOJailbreaker's physical duplicate-app protection. LaunchServices can
            // itself be stale, so checking only LSApplicationProxy is not sufficient here.
            NSString *userAppsPath = @"/var/containers/Bundle/Application";
            for (NSString *appUUID in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:userAppsPath error:nil]) {
                NSString *UUIDPath = [userAppsPath stringByAppendingPathComponent:appUUID];
                for (NSString *appCandidate in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:UUIDPath error:nil]) {
                    if (![appCandidate.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

                    NSString *userAppPath = [UUIDPath stringByAppendingPathComponent:appCandidate];
                    NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[userAppPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
                    if (!bundleIdentifier.length) continue;
                    NSString *jailbreakAppPath = applicationsByIdentifier[bundleIdentifier];
                    if (jailbreakAppPath) {
                        repairError = DOJailbreakAppUserConflictError(bundleIdentifier, jailbreakAppPath, userAppPath);
                        return;
                    }
                }
            }

            // Preflight every registration before mutating any of them. A mismatched path
            // that still exists is a real conflict; a missing old path is a repairable stale
            // registration (for example after a jbroot rerandomization).
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
            }

            BOOL needsFullRefresh = NO;
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateMatches) continue;
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }

                // Missing and stale registrations are both safe to repair in place. uicache
                // registration replaces the stale LS record without touching a live app path.
                exec_cmd(uicachePath, "-p", applicationPath.fileSystemRepresentation, NULL);

                state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
                if (state != DOJailbreakAppRegistrationStateMatches) {
                    needsFullRefresh = YES;
                }
            }

            if (needsFullRefresh) {
                // Re-check before the broad fallback so a registration that appeared
                // concurrently is never overwritten by a full refresh.
                needsFullRefresh = NO;
                for (NSString *bundleIdentifier in applicationsByIdentifier) {
                    NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                    NSString *registeredPath = nil;
                    DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (state == DOJailbreakAppRegistrationStateMatches) continue;
                    if (state == DOJailbreakAppRegistrationStateConflict) {
                        repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }
                    needsFullRefresh = YES;
                }
            }

            if (needsFullRefresh) {
                int result = exec_cmd(uicachePath, "-a", NULL);
                if (result != 0) {
                    repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                       code:result
                                                   userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to refresh jailbreak app registrations (uicache exit %d).", result]}];
                    return;
                }
            }

            NSMutableArray<NSString *> *remainingIssues = [NSMutableArray array];
            for (NSString *bundleIdentifier in applicationsByIdentifier) {
                NSString *applicationPath = applicationsByIdentifier[bundleIdentifier];
                NSString *registeredPath = nil;
                DOJailbreakAppRegistrationState state = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                if (state == DOJailbreakAppRegistrationStateConflict) {
                    repairError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                    return;
                }
                if (state != DOJailbreakAppRegistrationStateMatches) {
                    [remainingIssues addObject:bundleIdentifier];
                }
            }

            if (remainingIssues.count) {
                repairError = [NSError errorWithDomain:@"DOJailbreakAppRepairErrorDomain"
                                                   code:EIO
                                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Jailbreak app registration is still inconsistent for: %@", [remainingIssues componentsJoinedByString:@", "]]}];
            }
        }];
    }];

    if (!repairAttempted && !repairError) {
        repairError = [NSError errorWithDomain:NSPOSIXErrorDomain
                                           code:EPERM
                                       userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair jailbreak app registrations."}];
    }

    return repairError;
}

static NSString *DOPackageManagerHealthStateName(DOPackageManagerHealthState state)
{
    switch (state) {
        case DOPackageManagerHealthStateNotSelected: return @"Not Selected";
        case DOPackageManagerHealthStateHealthy: return @"Healthy";
        case DOPackageManagerHealthStateAppMissing: return @"App Missing";
        case DOPackageManagerHealthStateBundleInvalid: return @"Bundle Invalid";
        case DOPackageManagerHealthStateRegistrationMissing: return @"Registration Missing";
        case DOPackageManagerHealthStateRegistrationStale: return @"Registration Stale";
        case DOPackageManagerHealthStateRegistrationConflict: return @"Registration Conflict";
        case DOPackageManagerHealthStateInspectionFailed: return @"Inspection Failed";
    }
    return @"Unknown";
}

- (NSArray<NSDictionary<NSString *, id> *> *)packageManagerHealthReport
{
    NSArray<NSDictionary *> *packageManagers = [[DOUIManager sharedInstance] availablePackageManagers];
    NSSet<NSString *> *enabledPackageManagerKeys = [NSSet setWithArray:[[DOUIManager sharedInstance] enabledPackageManagerKeys]];
    __block NSMutableArray<NSDictionary<NSString *, id> *> *healthReport = [NSMutableArray arrayWithCapacity:packageManagers.count];

    [self runUnsandboxed:^{
        NSString *applicationsPath = JBROOT_PATH(@"/Applications");
        NSError *directoryError = nil;
        NSArray<NSString *> *applicationNames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:applicationsPath error:&directoryError];

        NSMutableDictionary<NSString *, NSString *> *applicationPathsByIdentifier = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *duplicateIdentifiers = [NSMutableSet set];
        for (NSString *applicationName in applicationNames ?: @[]) {
            if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
            NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
            NSString *bundleIdentifier = infoDictionary[@"CFBundleIdentifier"];
            if (!bundleIdentifier.length) continue;

            if (applicationPathsByIdentifier[bundleIdentifier]) {
                [duplicateIdentifiers addObject:bundleIdentifier];
            }
            else {
                applicationPathsByIdentifier[bundleIdentifier] = applicationPath;
            }
        }

        for (NSDictionary *packageManager in packageManagers) {
            NSString *displayName = packageManager[@"Display Name"];
            NSString *bundleIdentifier = packageManager[@"Key"];
            BOOL selected = bundleIdentifier.length && [enabledPackageManagerKeys containsObject:bundleIdentifier];
            DOPackageManagerHealthState state = DOPackageManagerHealthStateNotSelected;
            NSString *applicationPath = nil;
            NSString *registeredPath = nil;
            NSString *detail = nil;
            NSString *knownApplicationPath = bundleIdentifier.length ? applicationPathsByIdentifier[bundleIdentifier] : nil;
            NSString *namedApplicationPath = displayName.length ? [applicationsPath stringByAppendingPathComponent:[displayName stringByAppendingPathExtension:@"app"]] : nil;
            BOOL namedApplicationExists = namedApplicationPath.length && [[NSFileManager defaultManager] fileExistsAtPath:namedApplicationPath];
            BOOL packageManagerAppPresent = knownApplicationPath.length ||
                                            namedApplicationExists ||
                                            (bundleIdentifier.length && [duplicateIdentifiers containsObject:bundleIdentifier]);

            // Selection is a user preference, not a health gate. An unselected and
            // genuinely absent package manager remains Not Selected; any installed
            // package manager is inspected fully.
            if (selected || !applicationNames || packageManagerAppPresent) {
                NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                if (userAppPath) {
                    state = DOPackageManagerHealthStateRegistrationConflict;
                    detail = [NSString stringWithFormat:@"A user application with the same bundle identifier exists at %@.", userAppPath];
                }
                else if (!applicationNames) {
                    state = DOPackageManagerHealthStateInspectionFailed;
                    detail = directoryError.localizedDescription ?: @"Unable to enumerate jailbreak applications.";
                }
                else if ([duplicateIdentifiers containsObject:bundleIdentifier]) {
                    state = DOPackageManagerHealthStateBundleInvalid;
                    applicationPath = applicationPathsByIdentifier[bundleIdentifier];
                    detail = [NSString stringWithFormat:@"Multiple jailbreak applications use the bundle identifier %@.", bundleIdentifier];
                }
                else {
                    applicationPath = knownApplicationPath;
                    if (!applicationPath) {
                        registeredPath = DORegisteredApplicationPath(bundleIdentifier);

                        // When the current jbroot app is missing, a live registration at some
                        // other path is a conflict and must be surfaced before any reinstall.
                        // A missing registered path is only stale metadata and is repairable.
                        BOOL registeredPathExists = registeredPath.length && [[NSFileManager defaultManager] fileExistsAtPath:registeredPath];
                        NSString *canonicalNamedPath = DOCanonicalApplicationPath(namedApplicationPath);
                        BOOL registeredToNamedPath = registeredPathExists && canonicalNamedPath.length && [registeredPath isEqualToString:canonicalNamedPath];
                        if (registeredPathExists && !registeredToNamedPath) {
                            state = DOPackageManagerHealthStateRegistrationConflict;
                            detail = [NSString stringWithFormat:@"LaunchServices is registered to a live application at %@ while the current %@ application is missing.", registeredPath, displayName ?: bundleIdentifier];
                        }
                        else if (namedApplicationExists) {
                            applicationPath = namedApplicationPath;
                            state = DOPackageManagerHealthStateBundleInvalid;
                            detail = [NSString stringWithFormat:@"%@ exists but its bundle identifier does not match %@.", namedApplicationPath.lastPathComponent, bundleIdentifier];
                        }
                        else {
                            state = DOPackageManagerHealthStateAppMissing;
                            if (registeredPath.length) {
                                detail = [NSString stringWithFormat:@"The application is missing and LaunchServices still references the stale path %@.", registeredPath];
                            }
                        }
                    }
                    else {
                        DOJailbreakAppRegistrationState registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                        switch (registrationState) {
                            case DOJailbreakAppRegistrationStateMatches:
                                state = DOPackageManagerHealthStateHealthy;
                                break;
                            case DOJailbreakAppRegistrationStateMissing:
                                state = DOPackageManagerHealthStateRegistrationMissing;
                                break;
                            case DOJailbreakAppRegistrationStateStale:
                                state = DOPackageManagerHealthStateRegistrationStale;
                                break;
                            case DOJailbreakAppRegistrationStateConflict:
                                state = DOPackageManagerHealthStateRegistrationConflict;
                                break;
                        }
                    }
                }
            }

            NSMutableDictionary<NSString *, id> *entry = [@{
                @"DisplayName" : displayName ?: bundleIdentifier ?: @"Package Manager",
                @"BundleIdentifier" : bundleIdentifier ?: @"",
                @"Selected" : @(selected),
                @"State" : @(state),
                @"StateName" : DOPackageManagerHealthStateName(state),
            } mutableCopy];
            if (applicationPath.length) entry[@"ApplicationPath"] = DOCanonicalApplicationPath(applicationPath);
            if (registeredPath.length) entry[@"RegisteredPath"] = registeredPath;
            if (detail.length) entry[@"Detail"] = detail;
            [healthReport addObject:entry];
        }
    }];

    return healthReport.copy;
}

static BOOL DOPackageManagerBundleInvalidIsReinstallable(NSString *displayName, NSString *bundleIdentifier);

static NSDictionary<NSString *, id> *DORootHideHealthEntry(NSString *kind,
                                                              NSString *displayName,
                                                              NSString *stateName,
                                                              BOOL healthy,
                                                              BOOL repairable,
                                                              NSString *detail)
{
    NSMutableDictionary<NSString *, id> *entry = [@{
        @"Kind" : kind ?: @"Unknown",
        @"DisplayName" : displayName ?: @"RootHide Health",
        @"StateName" : stateName ?: @"Unknown",
        @"Healthy" : @(healthy),
        @"Repairable" : @(repairable),
    } mutableCopy];
    if (detail.length) entry[@"Detail"] = detail;
    return entry.copy;
}

- (NSArray<NSDictionary<NSString *, id> *> *)rootHideHealthReport
{
    NSMutableArray<NSDictionary<NSString *, id> *> *healthReport = [NSMutableArray array];
    BOOL bootstrapped = self.isBootstrapped;

    if (!bootstrapped) {
        [healthReport addObject:DORootHideHealthEntry(@"Bootstrap", @"Bootstrap", @"Not Bootstrapped", NO, NO,
                                                      @"No active RootHide jailbreak root is available.")];
        [healthReport addObject:DORootHideHealthEntry(@"JailbreakApps", @"Jailbreak Apps", @"Unavailable", NO, NO,
                                                      @"Jailbreak app health requires an installed bootstrap.")];
        for (NSDictionary *packageManager in [[DOUIManager sharedInstance] availablePackageManagers]) {
            NSString *displayName = packageManager[@"Display Name"] ?: packageManager[@"Key"] ?: @"Package Manager";
            [healthReport addObject:DORootHideHealthEntry(@"PackageManager", displayName, @"Unavailable", NO, NO,
                                                          @"Package manager health requires an installed bootstrap.")];
        }
        [healthReport addObject:DORootHideHealthEntry(@"Injection", @"Injection", @"Unavailable", NO, NO,
                                                      @"Injection health requires an installed bootstrap.")];
        return healthReport.copy;
    }

    __block NSMutableArray<NSString *> *missingBootstrapComponents = [NSMutableArray array];
    __block NSMutableArray<NSString *> *missingInjectionComponents = [NSMutableArray array];
    [self runUnsandboxed:^{
        NSFileManager *fileManager = [NSFileManager defaultManager];
        BOOL isDirectory = NO;
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/") isDirectory:&isDirectory] || !isDirectory)
            [missingBootstrapComponents addObject:@"jailbreak root"];
        isDirectory = NO;
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin") isDirectory:&isDirectory] || !isDirectory)
            [missingBootstrapComponents addObject:@"basebin"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/.installed_dopamine")])
            [missingBootstrapComponents addObject:@"install marker"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin/.version")])
            [missingBootstrapComponents addObject:@"basebin version"];
        if (access(JBROOT_PATH("/basebin/jbctl"), X_OK) != 0)
            [missingBootstrapComponents addObject:@"jbctl"];
        if (access(JBROOT_PATH("/usr/bin/uicache"), X_OK) != 0)
            [missingBootstrapComponents addObject:@"uicache"];
        if (access(JBROOT_PATH("/usr/bin/dpkg"), X_OK) != 0)
            [missingBootstrapComponents addObject:@"dpkg"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/var/lib/dpkg/status")])
            [missingBootstrapComponents addObject:@"dpkg status"];

        NSString *basebinPath = JBROOT_PATH(@"/basebin");
        BOOL systemhookPresent = [fileManager fileExistsAtPath:[basebinPath stringByAppendingPathComponent:@"systemhook.dylib"]];
        if (!systemhookPresent) {
            NSString *systemhookTemplate = @"systemhook-0000000000000000.dylib";
            NSCharacterSet *nonHexCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
            for (NSString *entryName in [fileManager contentsOfDirectoryAtPath:basebinPath error:nil]) {
                if (entryName.length != systemhookTemplate.length ||
                    ![entryName hasPrefix:@"systemhook-"] ||
                    ![entryName hasSuffix:@".dylib"]) continue;

                NSString *brandString = [entryName substringWithRange:NSMakeRange(@"systemhook-".length, 16)];
                if ([brandString rangeOfCharacterFromSet:nonHexCharacters].location != NSNotFound) continue;

                BOOL isDirectory = NO;
                NSString *candidatePath = [basebinPath stringByAppendingPathComponent:entryName];
                if ([fileManager fileExistsAtPath:candidatePath isDirectory:&isDirectory] && !isDirectory) {
                    systemhookPresent = YES;
                    break;
                }
            }
        }
        if (!systemhookPresent)
            [missingInjectionComponents addObject:@"systemhook.dylib"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin/roothidehooks.dylib")])
            [missingInjectionComponents addObject:@"roothidehooks.dylib"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin/launchdhook.dylib")])
            [missingInjectionComponents addObject:@"launchdhook.dylib"];
        if (access(JBROOT_PATH("/basebin/opainject"), X_OK) != 0)
            [missingInjectionComponents addObject:@"opainject"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin/libjailbreak.dylib")])
            [missingInjectionComponents addObject:@"basebin libjailbreak.dylib"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/usr/lib/libjailbreak.dylib")])
            [missingInjectionComponents addObject:@"libjailbreak.dylib link"];
        if (![fileManager fileExistsAtPath:JBROOT_PATH(@"/basebin/.fakelib/dyld")])
            [missingInjectionComponents addObject:@"patched dyld link"];
    }];

    BOOL bootstrapHealthy = missingBootstrapComponents.count == 0;
    [healthReport addObject:DORootHideHealthEntry(@"Bootstrap", @"Bootstrap",
                                                  bootstrapHealthy ? @"Healthy" : @"Needs Attention",
                                                  bootstrapHealthy, NO,
                                                  bootstrapHealthy ? nil : [NSString stringWithFormat:@"Missing: %@.", [missingBootstrapComponents componentsJoinedByString:@", "]])];

    NSArray<NSDictionary<NSString *, id> *> *jailbreakApps = [self jailbreakAppHealthReport];
    NSMutableArray<NSString *> *jailbreakAppIssues = [NSMutableArray array];
    BOOL jailbreakAppsRepairable = YES;
    NSString *singleJailbreakAppState = nil;
    for (NSDictionary<NSString *, id> *entry in jailbreakApps) {
        if ([entry[@"Healthy"] boolValue]) continue;
        NSString *displayName = entry[@"DisplayName"] ?: entry[@"BundleIdentifier"] ?: @"Jailbreak App";
        NSString *stateName = entry[@"StateName"] ?: @"Unknown";
        if (!singleJailbreakAppState) singleJailbreakAppState = stateName;
        [jailbreakAppIssues addObject:[NSString stringWithFormat:@"%@: %@", displayName, stateName]];
        if (![entry[@"Repairable"] boolValue]) jailbreakAppsRepairable = NO;
    }
    BOOL jailbreakAppsHealthy = jailbreakAppIssues.count == 0;
    NSString *jailbreakAppsState = jailbreakAppsHealthy ? @"Healthy" : (jailbreakAppIssues.count == 1 ? singleJailbreakAppState : @"Needs Attention");
    [healthReport addObject:DORootHideHealthEntry(@"JailbreakApps", @"Jailbreak Apps", jailbreakAppsState,
                                                  jailbreakAppsHealthy,
                                                  !jailbreakAppsHealthy && jailbreakAppsRepairable,
                                                  jailbreakAppsHealthy ? nil : [jailbreakAppIssues componentsJoinedByString:@"\n"])];

    for (NSDictionary<NSString *, id> *packageManagerEntry in [self packageManagerHealthReport]) {
        NSMutableDictionary<NSString *, id> *entry = [packageManagerEntry mutableCopy];
        DOPackageManagerHealthState state = [entry[@"State"] unsignedIntegerValue];
        BOOL selected = [entry[@"Selected"] boolValue];
        BOOL healthy = state == DOPackageManagerHealthStateHealthy || state == DOPackageManagerHealthStateNotSelected;
        BOOL repairable = NO;
        if (state == DOPackageManagerHealthStateRegistrationMissing ||
            state == DOPackageManagerHealthStateRegistrationStale) {
            repairable = [entry[@"ApplicationPath"] length] > 0;
        }
        else if (state == DOPackageManagerHealthStateAppMissing) {
            // Never install a package manager the user did not select.
            repairable = selected;
        }
        else if (state == DOPackageManagerHealthStateBundleInvalid) {
            NSString *displayName = entry[@"DisplayName"];
            NSString *bundleIdentifier = entry[@"BundleIdentifier"];
            __block BOOL reinstallable = NO;
            [self runUnsandboxed:^{
                reinstallable = DOPackageManagerBundleInvalidIsReinstallable(displayName, bundleIdentifier);
            }];
            repairable = selected && reinstallable;
        }
        entry[@"Kind"] = @"PackageManager";
        entry[@"Healthy"] = @(healthy);
        entry[@"Repairable"] = @(repairable);
        [healthReport addObject:entry.copy];
    }

    BOOL injectionHealthy = missingInjectionComponents.count == 0;
    [healthReport addObject:DORootHideHealthEntry(@"Injection", @"Injection",
                                                  injectionHealthy ? @"Healthy" : @"Component Missing",
                                                  injectionHealthy, NO,
                                                  injectionHealthy ? nil : [NSString stringWithFormat:@"Missing: %@.", [missingInjectionComponents componentsJoinedByString:@", "]])];

    return healthReport.copy;
}

static NSError *DOPackageManagerRepairError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:@"DOPackageManagerRepairErrorDomain"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description ?: @"Package manager repair failed."}];
}

static BOOL DOPackageManagerBundleInvalidIsReinstallable(NSString *displayName, NSString *bundleIdentifier)
{
    if (!displayName.length || !bundleIdentifier.length) return NO;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *applicationsPath = JBROOT_PATH(@"/Applications");
    NSUInteger matchingIdentifierCount = 0;
    for (NSString *applicationName in [fileManager contentsOfDirectoryAtPath:applicationsPath error:nil]) {
        if (![applicationName.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
        NSString *applicationPath = [applicationsPath stringByAppendingPathComponent:applicationName];
        NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[applicationPath stringByAppendingPathComponent:@"Info.plist"]];
        if ([infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier]) {
            matchingIdentifierCount++;
            if (matchingIdentifierCount > 1) return NO;
        }
    }
    if (matchingIdentifierCount != 0) return NO;

    NSString *namedApplicationPath = [applicationsPath stringByAppendingPathComponent:[displayName stringByAppendingPathExtension:@"app"]];
    if (![fileManager fileExistsAtPath:namedApplicationPath]) return NO;
    NSDictionary *infoDictionary = [NSDictionary dictionaryWithContentsOfFile:[namedApplicationPath stringByAppendingPathComponent:@"Info.plist"]];
    return ![infoDictionary[@"CFBundleIdentifier"] isEqualToString:bundleIdentifier];
}

- (NSError *)repairPackageManagersMatchingBundleIdentifier:(NSString * _Nullable)targetBundleIdentifier
                                               selectedOnly:(BOOL)selectedOnly
{
    NSArray<NSDictionary<NSString *, id> *> *initialReport = [self packageManagerHealthReport];
    NSArray<NSDictionary *> *availablePackageManagers = [[DOUIManager sharedInstance] availablePackageManagers];
    NSMutableDictionary<NSString *, NSDictionary *> *packageManagersByIdentifier = [NSMutableDictionary dictionary];
    for (NSDictionary *packageManager in availablePackageManagers) {
        NSString *bundleIdentifier = packageManager[@"Key"];
        if (bundleIdentifier.length) packageManagersByIdentifier[bundleIdentifier] = packageManager;
    }

    if (targetBundleIdentifier.length && !packageManagersByIdentifier[targetBundleIdentifier]) {
        return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Unknown package manager %@.", targetBundleIdentifier]);
    }

    NSMutableArray<NSString *> *packageManagersToInstall = [NSMutableArray array];
    BOOL needsUICache = NO;
    for (NSDictionary<NSString *, id> *entry in initialReport) {
        NSString *bundleIdentifier = entry[@"BundleIdentifier"];
        if (targetBundleIdentifier.length && ![bundleIdentifier isEqualToString:targetBundleIdentifier]) continue;
        if (selectedOnly && ![entry[@"Selected"] boolValue]) continue;

        NSString *displayName = entry[@"DisplayName"] ?: bundleIdentifier ?: @"Package Manager";
        DOPackageManagerHealthState state = [entry[@"State"] unsignedIntegerValue];
        if (state == DOPackageManagerHealthStateHealthy) continue;
        if (state == DOPackageManagerHealthStateNotSelected) {
            if (targetBundleIdentifier.length) {
                return DOPackageManagerRepairError(EPERM, [NSString stringWithFormat:@"%@ is not selected and is not installed; refusing to install it automatically.", displayName]);
            }
            continue;
        }

        NSDictionary *packageManager = packageManagersByIdentifier[bundleIdentifier];
        if (!packageManager) {
            return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Missing package manager configuration for %@.", displayName]);
        }
        if (state == DOPackageManagerHealthStateRegistrationConflict) {
            return DOPackageManagerRepairError(EEXIST, entry[@"Detail"] ?: [NSString stringWithFormat:@"Refusing to repair conflicting registration for %@.", displayName]);
        }
        if (state == DOPackageManagerHealthStateInspectionFailed) {
            return DOPackageManagerRepairError(EIO, entry[@"Detail"] ?: [NSString stringWithFormat:@"Unable to inspect %@ safely.", displayName]);
        }
        if (state == DOPackageManagerHealthStateBundleInvalid) {
            __block BOOL reinstallable = NO;
            [self runUnsandboxed:^{
                reinstallable = DOPackageManagerBundleInvalidIsReinstallable(displayName, bundleIdentifier);
            }];
            if (!reinstallable) {
                return DOPackageManagerRepairError(EEXIST, entry[@"Detail"] ?: [NSString stringWithFormat:@"%@ has an ambiguous jailbreak application layout that cannot be repaired safely.", displayName]);
            }
        }

        if ((state == DOPackageManagerHealthStateAppMissing ||
             state == DOPackageManagerHealthStateBundleInvalid) &&
            ![entry[@"Selected"] boolValue]) {
            return DOPackageManagerRepairError(EPERM, [NSString stringWithFormat:@"%@ is not selected; refusing to reinstall it automatically.", displayName]);
        }

        if (state == DOPackageManagerHealthStateAppMissing || state == DOPackageManagerHealthStateBundleInvalid) {
            NSString *packageName = packageManager[@"Package"];
            if (!packageName.length) {
                return DOPackageManagerRepairError(EINVAL, [NSString stringWithFormat:@"Missing bundled package configuration for %@.", displayName]);
            }
            NSString *packagePath = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:packageName];
            if (![[NSFileManager defaultManager] fileExistsAtPath:packagePath]) {
                return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Bundled package for %@ is missing: %@", displayName, packageName]);
            }
            [packageManagersToInstall addObject:bundleIdentifier];
        }
        needsUICache = YES;
    }

    if (needsUICache) {
        __block BOOL uicacheAvailable = NO;
        __block int uicacheErrorCode = ENOENT;
        [self runUnsandboxed:^{
            if (access(JBROOT_PATH("/usr/bin/uicache"), X_OK) == 0) {
                uicacheAvailable = YES;
            }
            else if (errno) {
                uicacheErrorCode = errno;
            }
        }];
        if (!uicacheAvailable) {
            return [NSError errorWithDomain:NSPOSIXErrorDomain code:uicacheErrorCode userInfo:nil];
        }
    }

    if (packageManagersToInstall.count) {
        __block NSError *installError = nil;
        __block BOOL rootAttempted = NO;
        [self runAsRoot:^{
            rootAttempted = YES;
            [self runUnsandboxed:^{
                for (NSString *bundleIdentifier in packageManagersToInstall) {
                    NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                    if (userAppPath) {
                        installError = DOPackageManagerRepairError(EEXIST, [NSString stringWithFormat:@"Refusing to install %@ because a user application with the same bundle identifier exists at %@.", bundleIdentifier, userAppPath]);
                        return;
                    }
                    installError = [self->_bootstrapper installPackageManagerWithKey:bundleIdentifier];
                    if (installError) return;
                }
            }];
        }];
        if (!rootAttempted && !installError) {
            installError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair package managers."}];
        }
        if (installError) return installError;
    }

    NSArray<NSDictionary<NSString *, id> *> *postInstallReport = [self packageManagerHealthReport];
    NSMutableArray<NSDictionary<NSString *, id> *> *registrationsToRepair = [NSMutableArray array];
    for (NSDictionary<NSString *, id> *entry in postInstallReport) {
        NSString *bundleIdentifier = entry[@"BundleIdentifier"];
        if (targetBundleIdentifier.length && ![bundleIdentifier isEqualToString:targetBundleIdentifier]) continue;
        if (selectedOnly && ![entry[@"Selected"] boolValue]) continue;

        DOPackageManagerHealthState state = [entry[@"State"] unsignedIntegerValue];
        if (state == DOPackageManagerHealthStateHealthy || state == DOPackageManagerHealthStateNotSelected) continue;
        if (state == DOPackageManagerHealthStateRegistrationMissing || state == DOPackageManagerHealthStateRegistrationStale) {
            [registrationsToRepair addObject:entry];
            continue;
        }

        NSString *displayName = entry[@"DisplayName"] ?: entry[@"BundleIdentifier"] ?: @"Package Manager";
        NSString *detail = entry[@"Detail"] ?: entry[@"StateName"] ?: @"Unknown state";
        return DOPackageManagerRepairError(state == DOPackageManagerHealthStateRegistrationConflict ? EEXIST : EIO, [NSString stringWithFormat:@"%@ is not safely repairable after reinstall: %@", displayName, detail]);
    }

    if (registrationsToRepair.count) {
        __block NSError *registrationError = nil;
        __block BOOL rootAttempted = NO;
        [self runAsRoot:^{
            rootAttempted = YES;
            [self runUnsandboxed:^{
                const char *uicachePath = JBROOT_PATH("/usr/bin/uicache");
                for (NSDictionary<NSString *, id> *entry in registrationsToRepair) {
                    NSString *bundleIdentifier = entry[@"BundleIdentifier"];
                    NSString *displayName = entry[@"DisplayName"] ?: bundleIdentifier ?: @"Package Manager";
                    NSString *applicationPath = entry[@"ApplicationPath"];
                    if (!applicationPath.length) {
                        registrationError = DOPackageManagerRepairError(EIO, [NSString stringWithFormat:@"Cannot determine the application path for %@.", displayName]);
                        return;
                    }

                    NSString *userAppPath = DOUserApplicationPathForBundleIdentifier(bundleIdentifier);
                    if (userAppPath) {
                        registrationError = DOPackageManagerRepairError(EEXIST, [NSString stringWithFormat:@"Refusing to register %@ because a user application with the same bundle identifier exists at %@.", displayName, userAppPath]);
                        return;
                    }

                    NSString *registeredPath = nil;
                    DOJailbreakAppRegistrationState registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (registrationState == DOJailbreakAppRegistrationStateMatches) continue;
                    if (registrationState == DOJailbreakAppRegistrationStateConflict) {
                        registrationError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }

                    int result = exec_cmd(uicachePath, "-p", applicationPath.fileSystemRepresentation, NULL);
                    registrationState = DOJailbreakAppRegistrationStateForPath(bundleIdentifier, applicationPath, &registeredPath);
                    if (registrationState == DOJailbreakAppRegistrationStateConflict) {
                        registrationError = DOJailbreakAppRegistrationConflictError(bundleIdentifier, DOCanonicalApplicationPath(applicationPath), registeredPath);
                        return;
                    }
                    if (registrationState != DOJailbreakAppRegistrationStateMatches) {
                        registrationError = DOPackageManagerRepairError(result != 0 ? result : EIO, [NSString stringWithFormat:@"Failed to register %@ after repair (uicache exit %d).", displayName, result]);
                        return;
                    }
                }
            }];
        }];
        if (!rootAttempted && !registrationError) {
            registrationError = [NSError errorWithDomain:NSPOSIXErrorDomain code:EPERM userInfo:@{NSLocalizedDescriptionKey : @"Failed to enter the root context required to repair package manager registrations."}];
        }
        if (registrationError) return registrationError;
    }

    BOOL targetVerified = !targetBundleIdentifier.length;
    for (NSDictionary<NSString *, id> *entry in [self packageManagerHealthReport]) {
        NSString *bundleIdentifier = entry[@"BundleIdentifier"];
        if (targetBundleIdentifier.length && ![bundleIdentifier isEqualToString:targetBundleIdentifier]) continue;
        if (targetBundleIdentifier.length) targetVerified = YES;
        if (selectedOnly && ![entry[@"Selected"] boolValue]) continue;
        if ([entry[@"State"] unsignedIntegerValue] != DOPackageManagerHealthStateHealthy) {
            NSString *displayName = entry[@"DisplayName"] ?: entry[@"BundleIdentifier"] ?: @"Package Manager";
            NSString *detail = entry[@"Detail"] ?: entry[@"StateName"] ?: @"Unknown state";
            return DOPackageManagerRepairError(EIO, [NSString stringWithFormat:@"%@ is still unhealthy after repair: %@", displayName, detail]);
        }
    }

    if (!targetVerified) {
        return DOPackageManagerRepairError(ENOENT, [NSString stringWithFormat:@"Unable to verify package manager %@ after repair.", targetBundleIdentifier]);
    }

    return nil;
}

- (NSError *)repairPackageManagers
{
    // Preserve the existing Picker / Settings batch semantics.
    return [self repairPackageManagersMatchingBundleIdentifier:nil selectedOnly:YES];
}

- (NSError *)repairPackageManagerWithBundleIdentifier:(NSString *)bundleIdentifier
{
    if (!bundleIdentifier.length) {
        return DOPackageManagerRepairError(EINVAL, @"Missing package manager bundle identifier.");
    }

    // Precise Health repair may fix an installed, unselected package manager,
    // but App Missing is still blocked above unless the user selected it.
    return [self repairPackageManagersMatchingBundleIdentifier:bundleIdentifier selectedOnly:NO];
}


- (NSArray<NSString *> *)fakeMountPaths
{
    __block NSArray<NSString *> *paths = @[];
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSDictionary *configuration = [NSDictionary dictionaryWithContentsOfFile:self.fakeMountConfigurationPath];
            if ([configuration[@"path"] isKindOfClass:[NSArray class]]) paths = configuration[@"path"];
        }];
    }];
    return paths;
}

- (BOOL)saveFakeMountPaths:(NSArray<NSString *> *)paths
{
    __block BOOL success = NO;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            NSString *configurationPath = self.fakeMountConfigurationPath;
            [[NSFileManager defaultManager] createDirectoryAtPath:[configurationPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            success = [@{@"path" : paths ?: @[]} writeToFile:configurationPath atomically:YES];
        }];
    }];
    return success;
}

- (int)setFakeMountPath:(NSString *)path mounted:(BOOL)mounted deleteMirror:(BOOL)deleteMirror
{
    NSString *standardPath = path.stringByStandardizingPath;
    if (![path isEqualToString:standardPath] || ![path hasPrefix:@"/"] || [path isEqualToString:@"/"]) return EINVAL;

    __block int result = EPERM;
    [self runAsRoot:^{
        [self runUnsandboxed:^{
            result = exec_cmd(JBROOT_PATH("/basebin/jbctl"), "internal", mounted ? "mount" : "unmount",
                              standardPath.fileSystemRepresentation, NULL);
            if (!mounted && deleteMirror && result == 0) {
                NSString *mirrorPath = [JBROOT_PATH(@"/mnt") stringByAppendingString:standardPath];
                [[NSFileManager defaultManager] removeItemAtPath:mirrorPath error:nil];
            }
        }];
    }];
    return result;
}

- (void)restoreFakeMounts
{
    for (NSString *path in self.fakeMountPaths) {
        int result = [self setFakeMountPath:path mounted:YES deleteMirror:NO];
        if (result != 0) NSLog(@"Failed restoring fake mount %@: %d", path, result);
    }
}


// --- ported from RC7 ---
- (NSString *)fakeMountConfigurationPath
{
    return JBROOT_PATH(@"/mnt/newFakePath.plist");
}

@end
