#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

// Adiciona extern "C" para compatibilidade com C++
#ifdef __cplusplus
extern "C" {
#endif

// Função para registrar logs no arquivo
void vcam_log(NSString *message);

// Função para registrar logs com formato, semelhante a NSLog
void vcam_logf(NSString *format, ...);

#ifdef __cplusplus
}
#endif

#endif /* LOGGER_H */
