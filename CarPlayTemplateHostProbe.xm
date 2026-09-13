#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <notify.h>

static NSString * const kTHWBundle = @"com.apple.CarPlayTemplateUIHost";
static NSString * const kTHWPreviewClass = @"CPSPagingTripPreviewsCardView";
static NSString * const kTHWETAClass = @"CPSNavigationETAView";
static const char *kTHWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static NSString * const kTHWLogPath = @"/var/mobile/VMLTemplateWeather.txt";
static NSString * const kTHWPayloadPath = @"/var/mobile/VMLWeatherPayload.plist";

static NSString *gTHWName = nil;
static NSString *gTHWAddress = nil;
static NSString *gTHWLastSentQuery = nil;
static NSDate *gTHWLastSentAt = nil;
static int gTHWNotifyToken = 0;
static BOOL gTHWFetching = NO;

static BOOL THWIsHost(void) { return [NSBundle.mainBundle.bundleIdentifier isEqualToString:kTHWBundle]; }

static void THWLog(NSString *format, ...) {
    va_list args; va_start(args, format); NSString *msg=[[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSString *line=[NSString stringWithFormat:@"%@ | %@\n",[NSDate date],msg?:@""]; NSData *data=[line dataUsingEncoding:NSUTF8StringEncoding]; NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm fileExistsAtPath:kTHWLogPath]){[data writeToFile:kTHWLogPath atomically:YES];return;} NSFileHandle *fh=[NSFileHandle fileHandleForWritingAtPath:kTHWLogPath]; if(!fh)return; @try{[fh seekToEndOfFile];[fh writeData:data];[fh closeFile];}@catch(__unused NSException *e){}
}

static NSArray<UIWindow *> *THWWindows(void){NSMutableArray *out=[NSMutableArray array];for(UIScene *raw in UIApplication.sharedApplication.connectedScenes){if(![raw isKindOfClass:UIWindowScene.class])continue;for(UIWindow *w in ((UIWindowScene *)raw).windows)if(w&&![out containsObject:w])[out addObject:w];}return out;}
static UIView *THWFindClass(UIView *root,NSString *className){if(!root)return nil;if([NSStringFromClass(root.class)isEqualToString:className])return root;for(UIView *sub in root.subviews){UIView *f=THWFindClass(sub,className);if(f)return f;}return nil;}
static UIView *THWVisibleClass(NSString *className){for(UIWindow *w in THWWindows()){if(w.hidden||w.alpha<=.01||!w.rootViewController.view)continue;UIView *f=THWFindClass(w.rootViewController.view,className);if(f&&!f.hidden&&f.alpha>.01)return f;}return nil;}
static void THWCollectText(UIView *view,NSMutableArray<NSString *> *out){if(!view||view.hidden||view.alpha<=.01)return;NSString *text=nil;if([view isKindOfClass:UILabel.class])text=((UILabel *)view).text;else if([view isKindOfClass:UIButton.class])text=((UIButton *)view).currentTitle;if(!text.length)text=view.accessibilityLabel;if(text.length){NSString *c=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(c.length&&![out containsObject:c])[out addObject:c];}for(UIView *sub in view.subviews)THWCollectText(sub,out);}
static NSString *THWAddressFromText(NSString *text){if(!text.length)return nil;NSArray *lines=[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];for(NSString *raw in [lines reverseObjectEnumerator]){NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];if(line.length>=12&&([line containsString:@","]||[line localizedCaseInsensitiveContainsString:@"Việt Nam"]))return line;}if(text.length>=20&&[text containsString:@","])return text;return nil;}
static BOOL THWGenericText(NSString *s){NSString *l=s.lowercaseString;for(NSString *b in @[@"bắt đầu",@"hủy",@"lộ trình khác",@"tuyến đường",@"phút",@"km",@"đến",@"qua "])if([l containsString:b])return YES;return NO;}

static void THWCaptureDestination(void){UIView *preview=THWVisibleClass(kTHWPreviewClass);if(!preview)return;NSMutableArray *texts=[NSMutableArray array];THWCollectText(preview,texts);NSString *name=nil,*address=nil;for(NSString *s in texts){NSString *a=THWAddressFromText(s);if(!address.length&&a.length)address=a;if(!name.length&&s.length>=2&&s.length<=100&&!THWGenericText(s)&&!a.length)name=s;}BOOL changed=NO;if(name.length&&![name isEqualToString:gTHWName]){gTHWName=[name copy];changed=YES;}if(address.length&&![address isEqualToString:gTHWAddress]){gTHWAddress=[address copy];changed=YES;}if(changed)THWLog(@"cached name=%@ address=%@",gTHWName?:@"<nil>",gTHWAddress?:@"<nil>");}
static BOOL THWNavigationActive(void){return THWVisibleClass(kTHWETAClass)!=nil;}

static void THWPostWeather(double tempC,NSInteger code,double windKmh){
    NSDictionary *payload=@{ @"name":gTHWName?:@"Điểm đến", @"address":gTHWAddress?:@"", @"temperature":@(tempC), @"weather_code":@(code), @"wind":@(windKmh), @"timestamp":@([[NSDate date] timeIntervalSince1970]) };
    BOOL wrote=[payload writeToFile:kTHWPayloadPath atomically:YES]; THWLog(@"payload wrote=%d path=%@ payload=%@",wrote,kTHWPayloadPath,payload);
    if(!gTHWNotifyToken){int token=0;uint32_t status=notify_register_check(kTHWWeatherNotify,&token);if(status!=NOTIFY_STATUS_OK){THWLog(@"notify_register_check failed=%u",status);return;}gTHWNotifyToken=token;}
    NSInteger temp10=(NSInteger)llround(tempC*10.0),wind10=(NSInteger)llround(MAX(0.0,windKmh)*10.0);uint64_t tempPacked=(uint64_t)MAX(0,MIN(65535,temp10+1000)),codePacked=(uint64_t)MAX(0,MIN(255,code)),windPacked=(uint64_t)MAX(0,MIN(65535,wind10));uint64_t state=tempPacked|(codePacked<<16)|(windPacked<<24);notify_set_state(gTHWNotifyToken,state);uint32_t p=notify_post(kTHWWeatherNotify);THWLog(@"posted weather name=%@ temp=%.1f code=%ld wind=%.1f post=%u",gTHWName?:@"Điểm đến",tempC,(long)code,windKmh,p);
}

static void THWFetchIfReady(void){THWCaptureDestination();if(!THWNavigationActive()||gTHWFetching)return;NSString *query=gTHWAddress.length?gTHWAddress:gTHWName;if(!query.length)return;if([query isEqualToString:gTHWLastSentQuery]&&gTHWLastSentAt&&[[NSDate date] timeIntervalSinceDate:gTHWLastSentAt]<300)return;gTHWFetching=YES;THWLog(@"geocode query=%@ name=%@",query,gTHWName?:@"<nil>");CLGeocoder *geocoder=[CLGeocoder new];[geocoder geocodeAddressString:query completionHandler:^(NSArray<CLPlacemark *> *placemarks,NSError *error){CLLocation *loc=placemarks.firstObject.location;if(error||!loc){THWLog(@"geocode failed=%@",error.localizedDescription?:@"none");gTHWFetching=NO;return;}NSString *u=[NSString stringWithFormat:@"https://api.open-meteo.com/v1/forecast?latitude=%.6f&longitude=%.6f&current=temperature_2m,weather_code,wind_speed_10m&timezone=auto",loc.coordinate.latitude,loc.coordinate.longitude];[[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:u] completionHandler:^(NSData *data,NSURLResponse *response,NSError *netError){if(netError||!data){THWLog(@"weather error=%@",netError.localizedDescription?:@"none");gTHWFetching=NO;return;}NSDictionary *json=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];NSDictionary *cur=[json isKindOfClass:NSDictionary.class]?json[@"current"]:nil;NSNumber *temp=cur[@"temperature_2m"],*code=cur[@"weather_code"],*wind=cur[@"wind_speed_10m"];if(!temp||!code){THWLog(@"weather parse failed current=%@",cur);gTHWFetching=NO;return;}gTHWLastSentQuery=[query copy];gTHWLastSentAt=[NSDate date];THWPostWeather(temp.doubleValue,code.integerValue,wind?wind.doubleValue:0);gTHWFetching=NO;}] resume];}];}
static void THWSchedule(void){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{THWFetchIfReady();});}

%hook UIView
- (void)didMoveToWindow{%orig;if(!THWIsHost()||!self.window)return;NSString *name=NSStringFromClass(self.class);if([name isEqualToString:kTHWPreviewClass])THWCaptureDestination();if([name isEqualToString:kTHWPreviewClass]||[name isEqualToString:kTHWETAClass])THWSchedule();}
%end
%hook UILabel
- (void)setText:(NSString *)text{%orig;if(!THWIsHost()||!self.window)return;UIView *v=self;while(v){if([NSStringFromClass(v.class)isEqualToString:kTHWPreviewClass]){THWCaptureDestination();THWSchedule();break;}v=v.superview;}}
%end
%ctor{@autoreleasepool{if(!THWIsHost())return;THWLog(@"16.16 destination payload sender loaded");dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1*NSEC_PER_SEC),dispatch_get_main_queue(),^{THWCaptureDestination();THWFetchIfReady();[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer){THWFetchIfReady();}];});}}
