//
//  DONavigationController.h
//  Dopamine
//
//  Created by tomt000 on 04/01/2024.
//

#import <UIKit/UIKit.h>
#import "UIImage+Blur.h"
#import "DOMainViewController.h"
#import "Transition/DOModalTransitionScale.h"
#import "Transition/DOModalTransitionPush.h"

NS_ASSUME_NONNULL_BEGIN

@interface DONavigationController : UINavigationController <UINavigationControllerDelegate>

- (void)setCustomGlassOfficialUIEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
