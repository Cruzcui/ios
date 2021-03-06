//
//  DDGAppDelegate.m
//  DuckDuckGo2
//
//  Created by Chris Heimark on 12/9/11.
//  Copyright (c) 2011 DuckDuckGo, Inc. All rights reserved.
//

#ifdef __APPLE__
#import "TargetConditionals.h"
#endif

#if !(TARGET_IPHONE_SIMULATOR) && (APPSTORE_BUILD==0)
#define ENABLE_HOCKEY 1
#else
#define ENABLE_HOCKEY 0
#endif

#import "DDGAppDelegate.h"
#import "DDGHistoryProvider.h"
#import "SDURLCache.h"
#import "DDGSettingsViewController.h"
#import "AFNetworking.h"
#import "DDGUnderViewController.h"
#import "DDGSearchController.h"
#import "DDGSearchHandler.h"
#import "NSString+URLEncodingDDG.h"
#import "DDGFirstRunViewController.h"
#import "DDGSlideOverMenuController.h"
#if ENABLE_HOCKEY
#import <HockeySDK/HockeySDK.h>
#endif
#import "DDGURLProtocol.h"

@interface DDGAppDelegate ()
@property (nonatomic, weak) id <DDGSearchHandler> searchHandler;
@property (readwrite, strong, nonatomic) NSManagedObjectContext *masterManagedObjectContext;
@property (readwrite, strong, nonatomic) NSManagedObjectContext *managedObjectContext;
@property (readwrite, strong, nonatomic) NSManagedObjectModel *managedObjectModel;
@property (readwrite, strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@end

@implementation DDGAppDelegate

static void uncaughtExceptionHandler(NSException *exception) {
    //Internal error reporting
    NSLog(@"CRASH: %@", exception);
    NSLog(@"Stack Trace: %@", [exception callStackSymbols]);
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [NSURLProtocol registerClass:[DDGURLProtocol class]];
    
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
    
    NSDate *referenceDate = [NSDate dateWithTimeIntervalSince1970:0];
    [[NSUserDefaults standardUserDefaults] setObject:referenceDate forKey:DDGLastRefreshAttemptKey];
    
    //Set the global URL cache to SDURLCache, which caches to disk
    SDURLCache *urlCache = [[SDURLCache alloc] initWithMemoryCapacity:1024*1024*2 // 2MB mem cache
                                                         diskCapacity:1024*1024*10 // 10MB disk cache
                                                             diskPath:[SDURLCache defaultCachePath]];
    [NSURLCache setSharedURLCache:urlCache];
    
    [[AFNetworkActivityIndicatorManager sharedManager] setEnabled:YES];
    
    //Audio session
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    BOOL ok; //I like this. Naming a variable ok. Very subtle.
    NSError *error = nil;
    ok = [audioSession setActive:NO error:&error];
    if (!ok)
        NSLog(@"%s audioSession setActive:NO error=%@", __PRETTY_FUNCTION__, error);

    ok = [audioSession setCategory:AVAudioSessionCategoryPlayback
                       withOptions:AVAudioSessionCategoryOptionMixWithOthers
                             error:&error];
    if (!ok)
        NSLog(@"%s setCategoryError=%@", __PRETTY_FUNCTION__, error);
        
    //Active your audio session.
    ok = [audioSession setActive:YES error:&error];
    if(!ok)
        NSLog(@"%s audioSession setActive:YES error=%@", __PRETTY_FUNCTION__, error);
    
    
    //Load default settings.
    [DDGSettingsViewController loadDefaultSettings];
    
#if ENABLE_HOCKEY==1
    // Setup Hockey
    [[BITHockeyManager sharedHockeyManager] configureWithIdentifier:@"a29176ab05b9fe95c2b006b585fdfc18"];
    [[BITHockeyManager sharedHockeyManager] startManager];
    [[BITHockeyManager sharedHockeyManager].authenticator authenticateInstallation];
#endif
  
    [[UINavigationBar appearance] setBackgroundColor:[UIColor duckLightGray]];
    [[UINavigationBar appearance] setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window setBackgroundColor:[UIColor duckNoContentColor]];
    
    //Configure the sliding view controller
    DDGUnderViewController *under = [[DDGUnderViewController alloc] initWithManagedObjectContext:self.managedObjectContext];
    self.searchHandler = under;
        
    DDGSlideOverMenuController *menuController = [[DDGSlideOverMenuController alloc] initWithMode:DDGSlideOverMenuModeHorizontal];
    menuController.menuViewController = under;
    menuController.viewDidAppearCompletion = ^(DDGSlideOverMenuController *slideOverMenuController) {
        if (![[NSUserDefaults standardUserDefaults] boolForKey:DDGUserDefaultHasShownFirstRunKey]) {
            DDGFirstRunViewController *firstRunViewController = [DDGFirstRunViewController new];
            [slideOverMenuController presentViewController:firstRunViewController animated:YES completion:nil];
        }
    };
    [self.window setRootViewController:menuController];
  
    int type = DDGViewControllerTypeHome;
    NSString *homeViewMode = [[NSUserDefaults standardUserDefaults] objectForKey:DDGSettingHomeView];
    if ([homeViewMode isEqualToString:DDGSettingHomeViewTypeRecents]) {
        type = DDGViewControllerTypeHistory;
    } else if ([homeViewMode isEqualToString:DDGSettingHomeViewTypeSaved]) {
        type = DDGViewControllerTypeSaved;
    } else if ([homeViewMode isEqualToString:DDGSettingHomeViewTypeDuck]) {
        type = DDGViewControllerTypeDuck;
    }
        
    UIViewController *homeController = [under viewControllerForType:type];
    menuController.contentViewController = homeController;
    
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation;
{
    //We can only open URLs from DDG.
    if(![[[url scheme] lowercaseString] isEqualToString:@"duckduckgo"])
        return NO;
    
    //Let's see what the query is.
    NSString *query = nil;
    NSArray *params = [[url query] componentsSeparatedByString:@"&"];
    for (NSString *param in params) {
        NSArray *pair = [param componentsSeparatedByString:@"="];
        if ([pair count] > 1 && [[[pair objectAtIndex:0] lowercaseString] isEqualToString:@"q"]) {
            query = [[pair objectAtIndex:1] URLDecodedStringDDG];
        }
    }
    
    if (query) {
        [self.searchHandler loadQueryOrURL:query];
    } else {
        [self.searchHandler prepareForUserInput];
    }

    return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application;
{
    [self save];

    [self clearCacheAndCookies];
}

- (void)applicationWillResignActive:(UIApplication *)application;
{
    [self save];
}

- (void)applicationDidEnterBackground:(UIApplication *)application;
{
    [self save];
}

#pragma mark - Clean up

- (void)clearCacheAndCookies
{
    __block UIBackgroundTaskIdentifier identifier = UIBackgroundTaskInvalid;

    identifier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^
    {
        identifier = UIBackgroundTaskInvalid;
    }];

    [[NSURLCache sharedURLCache] removeAllCachedResponses];

    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [storage cookies])
    {
       [storage deleteCookie:cookie];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];

    [[UIApplication sharedApplication] endBackgroundTask:identifier];
}

#pragma mark - Core Data stack

- (void)save;
{
    __block UIBackgroundTaskIdentifier identfier = UIBackgroundTaskInvalid;
    
    identfier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        identfier = UIBackgroundTaskInvalid;
    }];
    
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self.managedObjectContext performBlock:^{
        if (self.managedObjectContext.hasChanges) {
            NSError *error = nil;
            BOOL success = [self.managedObjectContext save:&error];
            if (!success && nil != error)
                NSLog(@"error: %@", error);
        }
        
        [self.masterManagedObjectContext performBlock:^{
            if (self.masterManagedObjectContext.hasChanges) {
                NSError *error = nil;
                BOOL success = [self.masterManagedObjectContext save:&error];
                if (!success && nil != error)
                    NSLog(@"error: %@", error);
            }
            [[UIApplication sharedApplication] endBackgroundTask:identfier];
        }];
    }];
}

- (void)managedObjectContextDidSave:(NSNotification *)notification {
    __block UIBackgroundTaskIdentifier identfier = UIBackgroundTaskInvalid;
    
    identfier = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        identfier = UIBackgroundTaskInvalid;
    }];
    
    [self.masterManagedObjectContext performBlock:^{
        if (self.masterManagedObjectContext.hasChanges) {
            NSError *error = nil;
            BOOL success = [self.masterManagedObjectContext save:&error];
            if (!success && nil != error)
                NSLog(@"error: %@", error);
        }
        [[UIApplication sharedApplication] endBackgroundTask:identfier];
    }];
}

// Returns the managed object context for the application.
// If the context doesn't already exist, it is created and bound to the persistent store coordinator for the application.
- (NSManagedObjectContext *)managedObjectContext
{    
    if (_managedObjectContext) {
        return _managedObjectContext;
    }
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    
    if (!_masterManagedObjectContext) {
        _masterManagedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [_masterManagedObjectContext setPersistentStoreCoordinator:coordinator];        
    }    
    
    if (coordinator) {
        _managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        [_managedObjectContext setParentContext:_masterManagedObjectContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(managedObjectContextDidSave:)
                                                     name:NSManagedObjectContextDidSaveNotification
                                                   object:_managedObjectContext];
    }
    
    return _managedObjectContext;
}

// Returns the managed object model for the application.
// If the model doesn't already exist, it is created from the application's model.
- (NSManagedObjectModel *)managedObjectModel
{
    if(_managedObjectModel) {
        return _managedObjectModel;
    }
    
    NSURL *modelURL = [[NSBundle mainBundle] URLForResource:@"Stories" withExtension:@"momd"];
    _managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    return _managedObjectModel;
}

// Returns the persistent store coordinator for the application.
// If the coordinator doesn't already exist, it is created and the application's store added to it.
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if(_persistentStoreCoordinator){
        return _persistentStoreCoordinator;
    }
    
    NSURL *storeURL = [[self applicationDocumentsDirectory] URLByAppendingPathComponent:@"Stories.sqlite"];
    
    NSError *error = nil;
    NSDictionary *options = @{NSMigratePersistentStoresAutomaticallyOption: @YES,
                              NSInferMappingModelAutomaticallyOption: @"YES"};
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    if (![_persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeURL options:options error:&error]) {
        /*
         Replace this implementation with code to handle the error appropriately.
         
         abort() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.
         
         Typical reasons for an error here include:
         * The persistent store is not accessible;
         * The schema for the persistent store is incompatible with current managed object model.
         Check the error message to determine what the actual problem was.
         
         
         If the persistent store is not accessible, there is typically something wrong with the file path. Often, a file URL is pointing into the application's resources directory instead of a writeable directory.
         
         If you encounter schema incompatibility errors during development, you can reduce their frequency by:
         * Simply deleting the existing store:
         [[NSFileManager defaultManager] removeItemAtURL:storeURL error:nil]
         
         * Performing automatic lightweight migration by passing the following dictionary as the options parameter:
         @{NSMigratePersistentStoresAutomaticallyOption:@YES, NSInferMappingModelAutomaticallyOption:@YES}
         
         Lightweight migration will only work for a limited set of schema changes; consult "Core Data Model Versioning and Data Migration Programming Guide" for details.
         
         */
        NSLog(@"Unresolved error %@, %@", error, [error userInfo]);
        abort();
    }
    
    return _persistentStoreCoordinator;
}

#pragma mark - Application's Documents directory

// Returns the URL to the application's Documents directory.
- (NSURL *)applicationDocumentsDirectory;
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
}

@end