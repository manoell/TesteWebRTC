#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void writeLog(NSString *format, ...);
void setLogLevel(int level);

#ifdef __cplusplus
}
#endif

#endif
