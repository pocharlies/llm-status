# LLM Status

Menu bar app nativa para macOS (AppKit, sin dependencias) que muestra en la
barra de menús las peticiones LLM en curso y la velocidad de decode global:

```
9 req · 141 tok/s
```

Pensada para clusters de inferencia propios (vLLM + LiteLLM): lee un endpoint
JSON con este shape (el de nuestro dashboard, `dgx.llm.live.v1`):

```json
{ "running": 9.0, "waiting": 0.0, "decode_tps": 150.0, "decode_tps_now": 141.3 }
```

- Sondeo cada 30 s, una sola petición.
- Color según estado (igual que los chips de nuestro dashboard): **verde**
  sirviendo, **naranja** con cola abierta, **gris** ocioso o sin lectura.
  Nunca rojo: ocioso no es un error.
- Menú al clic: detalle (en curso / en cola / decode ahora / media 2 min /
  última actualización), atajo al dashboard, refresco manual (⌘R) y salida.
- Sin icono en el Dock (`LSUIElement`), arranca con el login vía LaunchAgent.

## Build

```sh
./build.sh            # produce "LLM Status.app" en ./build y la instala en ~/Applications
./build.sh --install  # lo mismo, e instala el LaunchAgent y arranca
```

Requiere las Command Line Tools de Xcode (`xcode-select --install`).

## Configuración

Por defecto apunta a `https://dgx.lan.e-dani.com/api/llm/live`. Para otro
endpoint, exporta antes de arrancar (p. ej. en el plist del LaunchAgent):

| variable | defecto | qué es |
|---|---|---|
| `LLM_LIVE_URL` | `https://dgx.lan.e-dani.com/api/llm/live` | endpoint JSON |
| `LLM_DASHBOARD_URL` | `https://dgx.lan.e-dani.com/inferencia` | enlace del menú |

## Requisitos de red

El endpoint debe ser alcanzable desde el Mac y tener un certificado confiado
por el sistema (nosotros usamos Tailscale para llegar a la LAN).

## Licencia

MIT
