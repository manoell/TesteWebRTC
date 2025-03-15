#ifndef WEBRTCMANAGER_H
#define WEBRTCMANAGER_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>
#import <AVFoundation/AVFoundation.h>

@class FloatingWindow;

/**
 * Estado de conexão do WebRTCManager
 */
typedef NS_ENUM(NSInteger, WebRTCManagerState) {
    WebRTCManagerStateDisconnected,    // Desconectado do servidor WebRTC
    WebRTCManagerStateConnecting,      // Tentando conectar ao servidor WebRTC
    WebRTCManagerStateConnected,       // Conectado e pronto para receber frames
    WebRTCManagerStateError,           // Erro na conexão WebRTC
    WebRTCManagerStateReconnecting     // Reconectando após falha
};

/**
 * WebRTCManager
 *
 * Classe responsável pelo gerenciamento da conexão WebRTC.
 * Versão simplificada para foco na funcionalidade básica.
 */
@interface WebRTCManager : NSObject <RTCPeerConnectionDelegate, NSURLSessionWebSocketDelegate>

/**
 * Referência à janela flutuante para atualização de UI
 */
@property (nonatomic, weak) FloatingWindow *floatingWindow;

/**
 * Estado atual da conexão WebRTC
 */
@property (nonatomic, assign, readonly) WebRTCManagerState state;

/**
 * Endereço IP do servidor
 */
@property (nonatomic, strong) NSString *serverIP;

/**
 * Inicializa o gerenciador com referência à janela flutuante.
 * @param window FloatingWindow para atualização de interface.
 * @return Nova instância do gerenciador.
 */
- (instancetype)initWithFloatingWindow:(FloatingWindow *)window;

/**
 * Inicia a conexão WebRTC.
 * Configura WebRTC, conecta ao servidor de sinalização e inicia a negociação.
 */
- (void)startWebRTC;

/**
 * Encerra a conexão WebRTC.
 * Libera todos os recursos e fecha conexões.
 * @param userInitiated Indica se a desconexão foi solicitada pelo usuário
 */
- (void)stopWebRTC:(BOOL)userInitiated;

/**
 * Envia uma mensagem de despedida (bye) para o servidor WebRTC.
 * Utilizado para informar ao servidor sobre uma desconexão iminente.
 */
- (void)sendByeMessage;

/**
 * Coleta estatísticas de qualidade da conexão WebRTC.
 * @return Dicionário contendo estatísticas como RTT, perdas de pacotes, etc.
 */
- (NSDictionary *)getConnectionStats;

- (float)getEstimatedFps;

@end

#endif /* WEBRTCMANAGER_H */
