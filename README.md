# WebRTC Camera Preview Tweak

## Sobre o Projeto

Este é um tweak para iOS jailbroken que implementa um sistema de recepção WebRTC em alta qualidade para substituição de feed de câmera. O tweak cria uma janela flutuante que exibe um preview do stream WebRTC recebido e é capaz de se adaptar automaticamente às diferentes configurações de câmera do dispositivo.

## Funcionalidades

- **Janela flutuante**: Exibe o preview do stream recebido, com indicadores de status e controles
- **Recepção WebRTC**: Conecta a um servidor WebRTC e recebe vídeo em alta qualidade (suporte até 4K)
- **Auto-adaptação**: Detecta a resolução e taxa de quadros da câmera nativa e adapta o stream automaticamente
- **Preview em tempo real**: Mostra o vídeo recebido com baixa latência
- **Processamento otimizado**: Suporte para diferentes formatos de frame e alta eficiência
- **Manipulação de erros robusta**: Sistema de reconexão automática e tratamento de erros
- **Estatísticas detalhadas**: Coleta e exibe informações sobre qualidade do stream

## Estado Atual

O projeto está funcional para:
- Recepção e exibição do stream WebRTC
- Detecção de câmeras nativas
- Auto-adaptação da resolução e taxa de quadros
- Conversão otimizada de frames WebRTC para formatos nativos

## Próximos Passos

A próxima fase de implementação está planejada para a substituição do feed da câmera:
- **Hook de AVCaptureSession**: Implementação do código para interceptar o feed da câmera nativa (arquivo de exemplo incluído)
- **Injeção de Buffer**: Injeção do stream WebRTC adaptado no pipeline de captura da câmera
- **Compatibilidade com aplicativos**: Garantir funcionamento com diversos aplicativos que usam a câmera

## Tecnologias

- **WebRTC**: Biblioteca Google WebRTC para iOS
- **Node.js**: Servidor de sinalização WebSocket
- **Express**: Servidor web para interface HTML
- **AVFoundation**: Integração com o sistema de câmera do iOS
- **UIKit**: Interface gráfica nativa

## Requisitos

- **Sistema**: iOS 14.0 ou superior
- **Jailbreak**: Compatível com iOS jailbroken
- **Dependências**: Google WebRTC framework (instalado via CocoaPods)
- **Servidor**: Node.js com pacotes express, http, ws, cors, uuid

## Configuração

### Servidor

1. Instale as dependências:
   ```
   npm install
   ```

2. Execute o servidor:
   ```
   node server.js
   ```

3. Acesse a interface web:
   ```
   http://SEU_IP:8080
   ```

### Cliente (Tweak)

1. Atualize o IP do servidor no arquivo `WebRTCManager.m` (busque por `ws://192.168.0.178:8080`)

2. Instale as dependências via CocoaPods:
   ```
   pod install
   ```

3. Compile o tweak:
   ```
   make clean
   make
   make package
   ```

4. Instale no dispositivo:
   ```
   make install
   ```

## Uso

1. Execute o servidor no computador
2. Abra a interface web e inicie a transmissão na resolução desejada
3. No dispositivo iOS, a janela flutuante estará visível
4. Clique em "Ativar Preview" para iniciar a recepção
5. O preview do stream será exibido na janela

## Importante

- Para usar a janela flutuante em conjunto com outros aplicativos, certifique-se de que seu dispositivo está jailbroken
- Quando o feed substituído for implementado, o sistema detectará automaticamente a abertura da câmera em qualquer aplicativo e substituirá o feed pelo stream WebRTC

## Desenvolvimento

Este projeto pode ser expandido para incluir:
- Controles adicionais de qualidade do vídeo
- Suporte para outras fontes de vídeo além do WebRTC
- Filtros e efeitos em tempo real
- Controle remoto da câmera (zoom, foco, etc.)

## Licença

Este projeto é para uso pessoal e experimental.
