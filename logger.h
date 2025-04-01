#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// Função para escrever log normal
void writeLog(NSString *format, ...);

// Função para escrever log de erro
void writeErrorLog(NSString *format, ...);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
