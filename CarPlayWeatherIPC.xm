#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>

static const char *kCPWWeatherNotify = "com.sushibta.vmlspeedbubble.weather";
static NSString * const kCPWPayloadPath = @"/var/mobile/VMLWeatherPayload.plist";
static int gCPWToken = 0;
static UIWindow *gCPWWindow = nil;
static UIView *gCPWCard = nil;
static UIImageView *gCPWIcon = nil;
static UILabel *gCPWTemp = nil;
static UILabel *gCPWName = nil;
static UILabel *gCPWCondition = nil;
static UIImageView *gCPWChevron = nil;

static BOOL CPWIsCarPlayApp(void){return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"];}
static BOOL CPWSceneLooksCarPlay(UIWindowScene *scene){if(!scene)return NO;NSString *role=scene.session.role?:@"";if([role localizedCaseInsensitiveContainsString:@"CarPlay"])return YES;CGSize s=scene.screen.bounds.size;return s.width>s.height&&s.width>=300&&s.height<=500;}
static UIWindowScene *CPWFindScene(void){UIWindowScene *best=nil;CGFloat bestScore=-CGFLOAT_MAX;for(UIScene *raw in UIApplication.sharedApplication.connectedScenes){if(![raw isKindOfClass:UIWindowScene.class])continue;UIWindowScene *scene=(UIWindowScene *)raw;if(!CPWSceneLooksCarPlay(scene))continue;CGSize s=scene.screen.bounds.size;CGFloat score=s.width*s.height;if(!best||score>bestScore){best=scene;bestScore=score;}}return best;}

static NSString *CPWDescription(NSInteger code){if(code==0)return @"Trời nắng";if(code<=3)return @"Có mây";if(code==45||code==48)return @"Sương mù";if((code>=51&&code<=57)||(code>=61&&code<=67)||(code>=80&&code<=82))return @"Có mưa";if(code>=71&&code<=77)return @"Có tuyết";if(code>=95)return @"Có dông";return @"Thời tiết thay đổi";}
static NSString *CPWSymbolName(NSInteger code){if(code==0)return @"sun.max.fill";if(code<=3)return @"cloud.sun.fill";if(code==45||code==48)return @"cloud.fog.fill";if((code>=51&&code<=57)||(code>=61&&code<=67)||(code>=80&&code<=82))return @"cloud.rain.fill";if(code>=71&&code<=77)return @"cloud.snow.fill";if(code>=95)return @"cloud.bolt.rain.fill";return @"cloud.fill";}
static UIColor *CPWIconTint(NSInteger code){if(code==0)return [UIColor colorWithRed:1 green:.78 blue:.08 alpha:1];if((code>=51&&code<=57)||(code>=61&&code<=67)||(code>=80&&code<=82))return [UIColor colorWithRed:.30 green:.72 blue:1 alpha:1];if(code>=95)return [UIColor colorWithRed:.72 green:.55 blue:1 alpha:1];return UIColor.whiteColor;}

static void CPWEnsureWindow(void){
    if(!CPWIsCarPlayApp())return;UIWindowScene *scene=CPWFindScene();if(!scene)return;
    if(gCPWWindow&&gCPWWindow.windowScene!=scene){gCPWWindow.hidden=YES;gCPWWindow.rootViewController=nil;gCPWWindow=nil;gCPWCard=nil;gCPWIcon=nil;gCPWTemp=nil;gCPWName=nil;gCPWCondition=nil;gCPWChevron=nil;}
    CGRect bounds=scene.coordinateSpace.bounds;if(CGRectIsEmpty(bounds))bounds=scene.screen.bounds;
    if(!gCPWWindow){
        gCPWWindow=[[UIWindow alloc]initWithWindowScene:scene];gCPWWindow.backgroundColor=UIColor.clearColor;gCPWWindow.userInteractionEnabled=NO;
        UIViewController *vc=[UIViewController new];vc.view.backgroundColor=UIColor.clearColor;vc.view.userInteractionEnabled=NO;gCPWWindow.rootViewController=vc;
        UIView *card=[UIView new];card.backgroundColor=[UIColor colorWithWhite:.06 alpha:.94];card.layer.cornerRadius=18;card.layer.masksToBounds=YES;card.layer.borderWidth=.6;card.layer.borderColor=[UIColor colorWithWhite:1 alpha:.18].CGColor;card.hidden=YES;card.userInteractionEnabled=NO;[vc.view addSubview:card];gCPWCard=card;
        UIImageView *icon=[UIImageView new];icon.contentMode=UIViewContentModeScaleAspectFit;[card addSubview:icon];gCPWIcon=icon;
        UILabel *temp=[UILabel new];temp.textColor=UIColor.whiteColor;temp.font=[UIFont systemFontOfSize:32 weight:UIFontWeightSemibold];temp.adjustsFontSizeToFitWidth=YES;[card addSubview:temp];gCPWTemp=temp;
        UIView *sep=[UIView new];sep.tag=161601;sep.backgroundColor=[UIColor colorWithWhite:1 alpha:.18];[card addSubview:sep];
        UILabel *name=[UILabel new];name.textColor=UIColor.whiteColor;name.font=[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];name.numberOfLines=1;name.adjustsFontSizeToFitWidth=YES;name.minimumScaleFactor=.72;[card addSubview:name];gCPWName=name;
        UILabel *condition=[UILabel new];condition.textColor=[UIColor colorWithWhite:.82 alpha:1];condition.font=[UIFont systemFontOfSize:16 weight:UIFontWeightRegular];[card addSubview:condition];gCPWCondition=condition;
        UIImageView *chevron=[UIImageView new];chevron.image=[UIImage systemImageNamed:@"chevron.right"];chevron.tintColor=[UIColor colorWithWhite:.82 alpha:1];chevron.contentMode=UIViewContentModeScaleAspectFit;[card addSubview:chevron];gCPWChevron=chevron;
    }
    gCPWWindow.frame=bounds;gCPWWindow.rootViewController.view.frame=bounds;
    CGFloat width=MIN(bounds.size.width-30,640),height=86,x=(bounds.size.width-width)/2.0,y=MAX(10,bounds.size.height*.035);gCPWCard.frame=CGRectMake(x,y,width,height);
    CGFloat left=18,iconW=58,tempW=92,sepX=left+iconW+tempW+17;gCPWIcon.frame=CGRectMake(left,14,iconW,58);gCPWTemp.frame=CGRectMake(left+iconW+8,18,tempW,50);UIView *sep=[gCPWCard viewWithTag:161601];sep.frame=CGRectMake(sepX,15,1,56);CGFloat textX=sepX+22;CGFloat chevW=24;gCPWChevron.frame=CGRectMake(width-38,31,chevW,24);CGFloat textW=width-textX-54;gCPWName.frame=CGRectMake(textX,14,textW,31);gCPWCondition.frame=CGRectMake(textX,45,textW,24);
    CGFloat highest=UIWindowLevelAlert;for(UIWindow *w in scene.windows)if(w&&w!=gCPWWindow)highest=MAX(highest,w.windowLevel);gCPWWindow.windowLevel=MAX(UIWindowLevelAlert+250,highest+120);gCPWWindow.hidden=NO;gCPWWindow.alpha=1;
}

static NSDictionary *CPWPayload(void){NSDictionary *p=[NSDictionary dictionaryWithContentsOfFile:kCPWPayloadPath];return [p isKindOfClass:NSDictionary.class]?p:nil;}
static void CPWShowWeather(NSString *name,double tempC,NSInteger code,NSTimeInterval duration){dispatch_async(dispatch_get_main_queue(),^{CPWEnsureWindow();if(!gCPWCard)return;UIImageSymbolConfiguration *cfg=[UIImageSymbolConfiguration configurationWithPointSize:45 weight:UIImageSymbolWeightMedium scale:UIImageSymbolScaleLarge];gCPWIcon.image=[[UIImage systemImageNamed:CPWSymbolName(code) withConfiguration:cfg] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];gCPWIcon.tintColor=CPWIconTint(code);gCPWTemp.text=[NSString stringWithFormat:@"%.0f°C",tempC];gCPWName.text=name.length?name:@"Điểm đến";gCPWCondition.text=CPWDescription(code);gCPWCard.hidden=NO;gCPWCard.alpha=0;gCPWCard.transform=CGAffineTransformMakeTranslation(18,0);[UIView animateWithDuration:.24 animations:^{gCPWCard.alpha=1;gCPWCard.transform=CGAffineTransformIdentity;}];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(duration*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[UIView animateWithDuration:.22 animations:^{gCPWCard.alpha=0;gCPWCard.transform=CGAffineTransformMakeTranslation(14,0);} completion:^(__unused BOOL finished){gCPWCard.hidden=YES;gCPWCard.transform=CGAffineTransformIdentity;}];});});}
static void CPWReadWeather(int token){NSDictionary *p=CPWPayload();if(p){CPWShowWeather([p[@"name"] description],[p[@"temperature"] doubleValue],[p[@"weather_code"] integerValue],8);return;}uint64_t state=0;if(notify_get_state(token,&state)!=NOTIFY_STATUS_OK)return;NSInteger tp=(NSInteger)(state&0xFFFFULL),code=(NSInteger)((state>>16)&0xFFULL);double temp=((double)tp-1000)/10.0;CPWShowWeather(@"Điểm đến",temp,code,8);}
static void CPWStartReceiver(void){if(!CPWIsCarPlayApp()||gCPWToken)return;int token=0;uint32_t s=notify_register_dispatch(kCPWWeatherNotify,&token,dispatch_get_main_queue(),^(int incoming){gCPWToken=incoming;CPWReadWeather(incoming);});if(s==NOTIFY_STATUS_OK)gCPWToken=token;}
%ctor{@autoreleasepool{if(!CPWIsCarPlayApp())return;CPWStartReceiver();[[NSNotificationCenter defaultCenter]addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{CPWEnsureWindow();});}];}}
