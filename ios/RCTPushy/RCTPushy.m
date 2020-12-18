//
//  RCTPushy.m
//  RCTPushy
//
//  Created by LvBingru on 2/19/16.
//  Copyright © 2016 erica. All rights reserved.
//

#import "RCTPushy.h"
#import "RCTPushyDownloader.h"
#import "RCTPushyManager.h"


#import <React/RCTConvert.h>
#import <React/RCTLog.h>
// #import <React/RCTReloadCommand.h>

static NSString *const keyPushyInfo = @"REACTNATIVECN_PUSHY_INFO_KEY";
static NSString *const paramPackageVersion = @"packageVersion";
static NSString *const paramLastVersion = @"lastVersion";
static NSString *const paramCurrentVersion = @"currentVersion";
static NSString *const paramIsFirstTime = @"isFirstTime";
static NSString *const paramIsFirstLoadOk = @"isFirstLoadOK";
static NSString *const keyBlockUpdate = @"REACTNATIVECN_PUSHY_BLOCKUPDATE";
static NSString *const keyUuid = @"REACTNATIVECN_PUSHY_UUID";
static NSString *const keyFirstLoadMarked = @"REACTNATIVECN_PUSHY_FIRSTLOADMARKED_KEY";
static NSString *const keyRolledBackMarked = @"REACTNATIVECN_PUSHY_ROLLEDBACKMARKED_KEY";
static NSString *const KeyPackageUpdatedMarked = @"REACTNATIVECN_PUSHY_ISPACKAGEUPDATEDMARKED_KEY";

// app info
static NSString * const AppVersionKey = @"appVersion";
static NSString * const BuildVersionKey = @"buildVersion";

// file def
static NSString * const BUNDLE_FILE_NAME = @"index.bundlejs";
static NSString * const SOURCE_PATCH_NAME = @"__diff.json";
static NSString * const BUNDLE_PATCH_NAME = @"index.bundlejs.patch";

// error def
static NSString * const ERROR_OPTIONS = @"options error";
static NSString * const ERROR_BSDIFF = @"bsdiff error";
static NSString * const ERROR_FILE_OPERATION = @"file operation error";

// event def
static NSString * const EVENT_PROGRESS_DOWNLOAD = @"RCTPushyDownloadProgress";
// static NSString * const EVENT_PROGRESS_UNZIP = @"RCTPushyUnzipProgress";
static NSString * const PARAM_PROGRESS_HASH = @"hash";
static NSString * const PARAM_PROGRESS_RECEIVED = @"received";
static NSString * const PARAM_PROGRESS_TOTAL = @"total";


typedef NS_ENUM(NSInteger, PushyType) {
    PushyTypeFullDownload = 1,
    PushyTypePatchFromPackage = 2,
    PushyTypePatchFromPpk = 3,
};

static BOOL ignoreRollback = false;

@implementation RCTPushy {
    RCTPushyManager *_fileManager;
    bool hasListeners;
}

@synthesize methodQueue = _methodQueue;

RCT_EXPORT_MODULE(RCTPushy);

+ (NSURL *)bundleURL
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSDictionary *pushyInfo = [defaults dictionaryForKey:keyPushyInfo];
    if (pushyInfo) {
        NSString *curPackageVersion = [RCTPushy packageVersion];
        NSString *packageVersion = [pushyInfo objectForKey:paramPackageVersion];
        
        BOOL needClearPushyInfo = ![curPackageVersion isEqualToString:packageVersion];
        if (needClearPushyInfo) {
            [defaults setObject:nil forKey:keyPushyInfo];
            [defaults setObject:@(YES) forKey:KeyPackageUpdatedMarked];
            [defaults synchronize];
            // ...need clear files later
        }
        else {
            NSString *curVersion = pushyInfo[paramCurrentVersion];
            
            BOOL isFirstTime = [pushyInfo[paramIsFirstTime] boolValue];
            BOOL isFirstLoadOK = [pushyInfo[paramIsFirstLoadOk] boolValue];
            
            NSString *loadVersion = curVersion;
            BOOL needRollback = (!ignoreRollback && isFirstTime == NO && isFirstLoadOK == NO) || loadVersion.length<=0;
            if (needRollback) {
                loadVersion = [self rollback];
            }
            else if (isFirstTime && !ignoreRollback){
                // bundleURL may be called many times, ignore rollbacks before process restarted again.
                ignoreRollback = true;

                NSMutableDictionary *newInfo = [[NSMutableDictionary alloc] initWithDictionary:pushyInfo];
                newInfo[paramIsFirstTime] = @(NO);
                [defaults setObject:newInfo forKey:keyPushyInfo];
                [defaults setObject:@(YES) forKey:keyFirstLoadMarked];
                [defaults synchronize];
            }
            
            NSString *downloadDir = [RCTPushy downloadDir];
            while (loadVersion.length) {
                NSString *bundlePath = [[downloadDir stringByAppendingPathComponent:loadVersion] stringByAppendingPathComponent:BUNDLE_FILE_NAME];
                if ([[NSFileManager defaultManager] fileExistsAtPath:bundlePath isDirectory:NULL]) {
                    NSURL *bundleURL = [NSURL fileURLWithPath:bundlePath];
                    return bundleURL;
                } else {
                    RCTLogError(@"RCTPushy -- bundle version %@ not found", loadVersion);
                    loadVersion = [self rollback];
                }
            }
        }
    }
    
    return [RCTPushy binaryBundleURL];
}

+ (NSString *) rollback {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSDictionary *pushyInfo = [defaults dictionaryForKey:keyPushyInfo];
    NSString *lastVersion = pushyInfo[paramLastVersion];
    NSString *curPackageVersion = [RCTPushy packageVersion];
    if (lastVersion.length) {
        // roll back to last version
        [defaults setObject:@{paramCurrentVersion:lastVersion,
                              paramIsFirstTime:@(NO),
                              paramIsFirstLoadOk:@(YES),
                              paramPackageVersion:curPackageVersion}
                     forKey:keyPushyInfo];
    }
    else {
        // roll back to bundle
        [defaults setObject:nil forKey:keyPushyInfo];
    }
    [defaults setObject:@(YES) forKey:keyRolledBackMarked];
    [defaults synchronize];
    return lastVersion;
}

+ (BOOL)requiresMainQueueSetup {
    // only set to YES if your module initialization relies on calling UIKit!
	return NO;
}

- (NSDictionary *)constantsToExport
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    NSMutableDictionary *ret = [NSMutableDictionary new];
    ret[@"downloadRootDir"] = [RCTPushy downloadDir];
    ret[@"packageVersion"] = [RCTPushy packageVersion];
    ret[@"buildTime"] = [RCTPushy buildTime];
    ret[@"isRolledBack"] = [defaults objectForKey:keyRolledBackMarked];
    ret[@"isFirstTime"] = [defaults objectForKey:keyFirstLoadMarked];
    ret[@"blockUpdate"] = [defaults objectForKey:keyBlockUpdate];
    ret[@"uuid"] = [defaults objectForKey:keyUuid];
    NSDictionary *pushyInfo = [defaults dictionaryForKey:keyPushyInfo];
    ret[@"currentVersion"] = [pushyInfo objectForKey:paramCurrentVersion];
    
    // clear isFirstTimemarked
    if ([[defaults objectForKey:keyFirstLoadMarked] boolValue]) {
        [defaults setObject:nil forKey:keyFirstLoadMarked];
    }
    
    // clear rolledbackmark
    if ([[defaults objectForKey:keyRolledBackMarked] boolValue]) {
        [defaults setObject:nil forKey:keyRolledBackMarked];
        [self clearInvalidFiles];
    }
    
    // clear packageupdatemarked
    if ([[defaults objectForKey:KeyPackageUpdatedMarked] boolValue]) {
        [defaults setObject:nil forKey:KeyPackageUpdatedMarked];
        [self clearInvalidFiles];
    }
    [defaults synchronize];

    return ret;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _fileManager = [RCTPushyManager new];
    }
    return self;
}

RCT_EXPORT_METHOD(setBlockUpdate:(NSDictionary *)options)
{
    // NSMutableDictionary *blockUpdateInfo = [NSMutableDictionary new];
    // blockUpdateInfo[@"reason"] = options[@"reason"];
    // blockUpdateInfo[@"until"] = options[@"until"];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:options forKey:keyBlockUpdate];
    [defaults synchronize];
}

RCT_EXPORT_METHOD(setUuid:(NSString *)uuid)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:uuid forKey:keyUuid];
    [defaults synchronize];
}

RCT_EXPORT_METHOD(downloadUpdate:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPushy:PushyTypeFullDownload options:options callback:^(NSError *error) {
        if (error) {
            reject([NSString stringWithFormat: @"%lu", (long)error.code], error.localizedDescription, error);
        }
        else {
            resolve(nil);
        }
    }];
}

RCT_EXPORT_METHOD(downloadPatchFromPackage:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPushy:PushyTypePatchFromPackage options:options callback:^(NSError *error) {
        if (error) {
            reject([NSString stringWithFormat: @"%lu", (long)error.code], error.localizedDescription, error);
        }
        else {
            resolve(nil);
        }
    }];
}

RCT_EXPORT_METHOD(downloadPatchFromPpk:(NSDictionary *)options
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    [self doPushy:PushyTypePatchFromPpk options:options callback:^(NSError *error) {
        if (error) {
            reject([NSString stringWithFormat: @"%lu", (long)error.code], error.localizedDescription, error);
        }
        else {
            resolve(nil);
        }
    }];
}

RCT_EXPORT_METHOD(setNeedUpdate:(NSDictionary *)options)
{
    NSString *hash = options[@"hash"];
    if (hash.length <= 0) {
        hash = options[@"hashName"];
    }
    if (hash.length) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *lastVersion = nil;
        if ([defaults objectForKey:keyPushyInfo]) {
            NSDictionary *pushyInfo = [defaults objectForKey:keyPushyInfo];
            lastVersion = pushyInfo[paramCurrentVersion];
        }
        
        NSMutableDictionary *newInfo = [[NSMutableDictionary alloc] init];
        newInfo[paramCurrentVersion] = hash;
        newInfo[paramLastVersion] = lastVersion;
        newInfo[paramIsFirstTime] = @(YES);
        newInfo[paramIsFirstLoadOk] = @(NO);
        newInfo[paramPackageVersion] = [RCTPushy packageVersion];
        [defaults setObject:newInfo forKey:keyPushyInfo];
        
        [defaults synchronize];
    }
}

RCT_EXPORT_METHOD(reloadUpdate:(NSDictionary *)options)
{
    NSString *hash = options[@"hash"];
    if (hash.length <= 0) {
        hash = options[@"hashName"];
    }
    if (hash.length) {
        [self setNeedUpdate:options];
        
        // reload 0.62+
        // RCTReloadCommandSetBundleURL([[self class] bundleURL]);
        // RCTTriggerReloadCommandListeners(@"pushy reload");
        
       dispatch_async(dispatch_get_main_queue(), ^{
           [self.bridge setValue:[[self class] bundleURL] forKey:@"bundleURL"];
           [self.bridge reload];
       });
    }
}

RCT_EXPORT_METHOD(markSuccess)
{
    // up package info
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *packageInfo = [[NSMutableDictionary alloc] initWithDictionary:[defaults objectForKey:keyPushyInfo]];
    [packageInfo setObject:@(NO) forKey:paramIsFirstTime];
    [packageInfo setObject:@(YES) forKey:paramIsFirstLoadOk];
    [defaults setObject:packageInfo forKey:keyPushyInfo];
    [defaults synchronize];
    
    // clear other package dir
    [self clearInvalidFiles];
}



#pragma mark - private
- (NSArray<NSString *> *)supportedEvents
{
  return @[
      EVENT_PROGRESS_DOWNLOAD, 
    //   EVENT_PROGRESS_UNZIP
      ];
}

// Will be called when this module's first listener is added.
-(void)startObserving {
    hasListeners = YES;
    // Set up any upstream listeners or background tasks as necessary
}

// Will be called when this module's last listener is removed, or on dealloc.
-(void)stopObserving {
    hasListeners = NO;
    // Remove upstream listeners, stop unnecessary background tasks
}


- (void)doPushy:(PushyType)type options:(NSDictionary *)options callback:(void (^)(NSError *error))callback
{
    NSString *updateUrl = [RCTConvert NSString:options[@"updateUrl"]];
    NSString *hash = [RCTConvert NSString:options[@"hash"]];
    if (hash.length <= 0) {
        hash = [RCTConvert NSString:options[@"hashName"]];;
    }
    if (updateUrl.length <= 0 || hash.length <= 0) {
        callback([self errorWithMessage:ERROR_OPTIONS]);
        return;
    }
    NSString *originHash = [RCTConvert NSString:options[@"originHash"]];
    if (type == PushyTypePatchFromPpk && originHash <= 0) {
        callback([self errorWithMessage:ERROR_OPTIONS]);
        return;
    }
    
    NSString *dir = [RCTPushy downloadDir];
    BOOL success = [_fileManager createDir:dir];
    if (!success) {
        callback([self errorWithMessage:ERROR_FILE_OPERATION]);
        return;
    }

    NSString *zipFilePath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@",hash, [self zipExtension:type]]];
//    NSString *unzipDir = [dir stringByAppendingPathComponent:hash];

    RCTLogInfo(@"RCTPushy -- download file %@", updateUrl);
    [RCTPushyDownloader download:updateUrl savePath:zipFilePath progressHandler:^(long long receivedBytes, long long totalBytes) {
        if (self->hasListeners) {
            [self sendEventWithName:EVENT_PROGRESS_DOWNLOAD body:@{
                PARAM_PROGRESS_HASH:hash,
                PARAM_PROGRESS_RECEIVED:[NSNumber numberWithLongLong:receivedBytes],
                PARAM_PROGRESS_TOTAL:[NSNumber numberWithLongLong:totalBytes]
            }];
        }
    } completionHandler:^(NSString *path, NSError *error) {
        if (error) {
            callback(error);
        }
        else {
            RCTLogInfo(@"RCTPushy -- unzip file %@", zipFilePath);
            NSString *unzipFilePath = [dir stringByAppendingPathComponent:hash];
            [self->_fileManager unzipFileAtPath:zipFilePath toDestination:unzipFilePath progressHandler:^(NSString *entry,long entryNumber, long total) {
                // if (self->hasListeners) {
                //     [self sendEventWithName:EVENT_PROGRESS_UNZIP
                //                        body:@{
                //                            PARAM_PROGRESS_HASH:hash,
                //                            PARAM_PROGRESS_RECEIVED:[NSNumber numberWithLong:entryNumber],
                //                            PARAM_PROGRESS_TOTAL:[NSNumber numberWithLong:total]
                //                        }];
                // }
                
            } completionHandler:^(NSString *path, BOOL succeeded, NSError *error) {
                dispatch_async(self->_methodQueue, ^{
                    if (error) {
                        callback(error);
                    }
                    else {
                        switch (type) {
                            case PushyTypePatchFromPackage:
                            {
                                NSString *sourceOrigin = [[NSBundle mainBundle] resourcePath];
                                NSString *bundleOrigin = [[RCTPushy binaryBundleURL] path];
                                [self patch:hash fromBundle:bundleOrigin source:sourceOrigin callback:callback];
                            }
                                break;
                            case PushyTypePatchFromPpk:
                            {
                                NSString *lastVersionDir = [dir stringByAppendingPathComponent:originHash];
                                
                                NSString *sourceOrigin = lastVersionDir;
                                NSString *bundleOrigin = [lastVersionDir stringByAppendingPathComponent:BUNDLE_FILE_NAME];
                                [self patch:hash fromBundle:bundleOrigin source:sourceOrigin callback:callback];
                            }
                                break;
                            default:
                                callback(nil);
                                break;
                        }
                    }
                });
            }];
        }
    }];
}

- (void)patch:(NSString *)hash fromBundle:(NSString *)bundleOrigin source:(NSString *)sourceOrigin callback:(void (^)(NSError *error))callback
{
    NSString *unzipDir = [[RCTPushy downloadDir] stringByAppendingPathComponent:hash];
    NSString *sourcePatch = [unzipDir stringByAppendingPathComponent:SOURCE_PATCH_NAME];
    NSString *bundlePatch = [unzipDir stringByAppendingPathComponent:BUNDLE_PATCH_NAME];
    
    NSString *destination = [unzipDir stringByAppendingPathComponent:BUNDLE_FILE_NAME];
    [_fileManager bsdiffFileAtPath:bundlePatch fromOrigin:bundleOrigin toDestination:destination completionHandler:^(BOOL success) {
        if (success) {
            NSData *data = [NSData dataWithContentsOfFile:sourcePatch];
            NSError *error = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
            if (error) {
                callback(error);
                return;
            }
            
            NSDictionary *copies = json[@"copies"];
            NSDictionary *deletes = json[@"deletes"];

            [self->_fileManager copyFiles:copies fromDir:sourceOrigin toDir:unzipDir deletes:deletes completionHandler:^(NSError *error) {
                if (error) {
                    callback(error);
                }
                else {
                    callback(nil);
                }
            }];
        }
        else {
            callback([self errorWithMessage:ERROR_BSDIFF]);
        }
    }];
}

- (void)clearInvalidFiles
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *pushyInfo = [defaults objectForKey:keyPushyInfo];
    NSString *curVersion = [pushyInfo objectForKey:paramCurrentVersion];
    
    NSString *downloadDir = [RCTPushy downloadDir];
    NSError *error = nil;
    NSArray *list = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:downloadDir error:&error];
    if (error) {
        return;
    }
    
    for(NSString *fileName in list) {
        if (![fileName isEqualToString:curVersion]) {
            [_fileManager removeFile:[downloadDir stringByAppendingPathComponent:fileName] completionHandler:nil];
        }
    }
}

- (NSString *)zipExtension:(PushyType)type
{
    switch (type) {
        case PushyTypeFullDownload:
            return @".ppk";
        case PushyTypePatchFromPackage:
            return @".ipa.patch";
        case PushyTypePatchFromPpk:
            return @".ppk.patch";
        default:
            break;
    }
}

- (NSError *)errorWithMessage:(NSString *)errorMessage
{
    return [NSError errorWithDomain:@"cn.reactnative.pushy"
                               code:-1
                           userInfo:@{ NSLocalizedDescriptionKey: errorMessage}];
}

+ (NSString *)downloadDir
{
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *downloadDir = [directory stringByAppendingPathComponent:@"rctpushy"];
    
    return downloadDir;
}

+ (NSURL *)binaryBundleURL
{
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"main" withExtension:@"jsbundle"];
    return url;
}

+ (NSString *)packageVersion
{
    static NSString *version = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *infoDictionary = [[NSBundle mainBundle] infoDictionary];
        version = [infoDictionary objectForKey:@"CFBundleShortVersionString"];
    });
    return version;
}

+ (NSString *)buildTime
{
#if DEBUG
    return @"0";
#else
    static NSString *buildTime;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      NSString *buildTimePath = [[NSBundle mainBundle] pathForResource:@"pushy_build_time" ofType:@"txt"];
      buildTime = [[NSString stringWithContentsOfFile:buildTimePath encoding:NSUTF8StringEncoding error:nil]
                 stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    });
    return buildTime;
#endif
}

@end
