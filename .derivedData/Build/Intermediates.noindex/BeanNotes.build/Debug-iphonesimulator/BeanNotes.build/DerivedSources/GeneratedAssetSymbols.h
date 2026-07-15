#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "BeanBadge" asset catalog image resource.
static NSString * const ACImageNameBeanBadge AC_SWIFT_PRIVATE = @"BeanBadge";

/// The "BeanPaperTexture" asset catalog image resource.
static NSString * const ACImageNameBeanPaperTexture AC_SWIFT_PRIVATE = @"BeanPaperTexture";

/// The "BeanTabAvatar" asset catalog image resource.
static NSString * const ACImageNameBeanTabAvatar AC_SWIFT_PRIVATE = @"BeanTabAvatar";

/// The "BeanWelcomeImage" asset catalog image resource.
static NSString * const ACImageNameBeanWelcomeImage AC_SWIFT_PRIVATE = @"BeanWelcomeImage";

/// The "BlueberryBadge" asset catalog image resource.
static NSString * const ACImageNameBlueberryBadge AC_SWIFT_PRIVATE = @"BlueberryBadge";

/// The "BlueberryPaperTexture" asset catalog image resource.
static NSString * const ACImageNameBlueberryPaperTexture AC_SWIFT_PRIVATE = @"BlueberryPaperTexture";

/// The "BlueberryVisitImage" asset catalog image resource.
static NSString * const ACImageNameBlueberryVisitImage AC_SWIFT_PRIVATE = @"BlueberryVisitImage";

#undef AC_SWIFT_PRIVATE
