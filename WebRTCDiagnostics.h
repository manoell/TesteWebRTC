#ifndef WEBRTCDIAGNOSTICS_H
#define WEBRTCDIAGNOSTICS_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/**
 * WebRTCDiagnostics
 *
 * Classe para diagnóstico e monitoramento de desempenho do WebRTC.
 * Fornece dados de telemetria, detecção de problemas e geração de relatórios.
 */
@interface WebRTCDiagnostics : NSObject

/**
 * Singleton para acesso global.
 */
+ (instancetype)sharedInstance;

/**
 * Inicia o monitoramento de desempenho.
 * @param interval Intervalo em segundos para coleta de métricas (default: 2.0).
 */
- (void)startMonitoring:(NSTimeInterval)interval;

/**
 * Para o monitoramento.
 */
- (void)stopMonitoring;

/**
 * Registra um evento de conexão.
 * @param eventType Tipo do evento (e.g., "connected", "disconnected", "error").
 * @param details Detalhes adicionais do evento.
 */
- (void)logConnectionEvent:(NSString *)eventType details:(NSDictionary *)details;

/**
 * Registra métricas de performance do vídeo.
 * @param resolution Resolução do vídeo.
 * @param fps Frames por segundo.
 * @param bitrate Bitrate em kbps.
 */
- (void)logVideoMetrics:(CGSize)resolution fps:(float)fps bitrate:(float)bitrate;

/**
 * Registra métricas de rede.
 * @param rtt Round-trip time em milissegundos.
 * @param packetLoss Taxa de perda de pacotes em percentual.
 * @param jitter Jitter em milissegundos.
 */
- (void)logNetworkMetrics:(float)rtt packetLoss:(float)packetLoss jitter:(float)jitter;

/**
 * Adiciona um erro crítico ao log de diagnóstico.
 * @param error Descrição do erro.
 * @param errorCode Código do erro.
 * @param details Detalhes adicionais.
 */
- (void)logCriticalError:(NSString *)error code:(int)errorCode details:(NSDictionary *)details;

/**
 * Obtém um relatório completo de diagnóstico.
 * @return String formatada com todas as informações coletadas.
 */
- (NSString *)generateDiagnosticReport;

/**
 * Obtém estatísticas resumidas.
 * @return Dicionário com estatísticas de desempenho.
 */
- (NSDictionary *)getPerformanceStats;

/**
 * Detecta e relata problemas potenciais com base nas métricas coletadas.
 * @return Array de strings descrevendo os problemas detectados.
 */
- (NSArray<NSString *> *)detectPotentialIssues;

/**
 * Salva o relatório de diagnóstico em um arquivo.
 * @return Caminho para o arquivo salvo ou nil em caso de erro.
 */
- (NSString *)saveDiagnosticReport;

/**
 * Limpa dados de diagnóstico antigos.
 */
- (void)clearDiagnosticData;

/**
 * Envia dados de diagnóstico para análise (simulado).
 * @param completionHandler Callback com resultado do envio.
 */
- (void)sendDiagnosticData:(void(^)(BOOL success, NSError *error))completionHandler;

@end

#endif /* WEBRTCDIAGNOSTICS_H */
