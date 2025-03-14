#ifndef LOGGER_H
#define LOGGER_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Escreve uma mensagem de log com formatação.
 * As mensagens são registradas no console e, dependendo do nível de log,
 * em um arquivo de log em /var/tmp/testeWebRTC.log.
 *
 * @param format String de formato para a mensagem.
 * @param ... Argumentos variáveis para formatação.
 */
void writeLog(NSString *format, ...);

/**
 * Define o nível de log.
 * 0 = Sem logging
 * 1 = Apenas erros críticos
 * 2 = Erros
 * 3 = Avisos e erros (padrão)
 * 4 = Informações, avisos e erros (com log em arquivo)
 * 5 = Verbose (tudo, com log em arquivo)
 *
 * @param level Nível de log (0-5).
 */
void setLogLevel(int level);

/**
 * Obtém o nível de log atual.
 *
 * @return Nível de log atual.
 */
int getLogLevel(void);

/**
 * Define o caminho do arquivo de log.
 * Por padrão é /var/tmp/testeWebRTC.log.
 *
 * @param path Caminho para o arquivo de log.
 */
void setLogPath(NSString *path);

/**
 * Limpa o arquivo de log atual.
 */
void clearLogFile(void);

#ifdef __cplusplus
}
#endif

#endif
