#import <UIKit/UIKit.h>

@interface ExportFilesFixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ExportFilesFixtureDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSFileManager *files = NSFileManager.defaultManager;
    NSError *error = nil;
    NSURL *documents = [files URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:&error];
    NSURL *exports = [documents URLByAppendingPathComponent:@"Exports" isDirectory:YES];
    BOOL ready = documents && [files createDirectoryAtURL:exports withIntermediateDirectories:YES attributes:nil error:&error];
    if (ready) ready = [@"SDI export fixture ready\n" writeToURL:[documents URLByAppendingPathComponent:@".sdi-export-fixture-ready"]
                                                  atomically:YES encoding:NSUTF8StringEncoding error:&error];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.textAlignment = NSTextAlignmentCenter;
    label.text = ready ? @"SDI Export Test Files ready" : @"SDI Export Test Files setup failed";
    label.accessibilityIdentifier = ready ? @"sdi.export-fixture.ready" : @"sdi.export-fixture.failed";
    [controller.view addSubview:label];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ExportFilesFixtureDelegate.class)); }
}
