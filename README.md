# Claude Mac Widgets

Widgets de escritorio para macOS, en un solo archivo SwiftUI sin dependencias. Flotan sobre el fondo de pantalla y se actualizan cada 60 s.

- **Claude Code**: límites de 5 horas y semanal con la barra de progreso de tu plan (verde, amarillo, naranja, rojo).
- **Git**: rama y cambios de tus repos recientes.
- **GitHub**: PRs pendientes de tu revisión.
- **GitHub Actions**: últimas corridas de CI.
- **Dev servers**: servidores locales y sus puertos.
- **Contribuciones**: tu mapa de calor.

## Requisitos

- macOS 13 o superior.
- Herramientas de línea de comandos de Xcode: `xcode-select --install`.
- [GitHub CLI](https://cli.github.com): `brew install gh` y luego `gh auth login`.
- Claude Code con sesión iniciada, para los límites reales (ver abajo).

## Instalación

```bash
git clone https://github.com/ItsYusei99/Claude-Mac-Widgets.git
cd Claude-Mac-Widgets
swiftc -O DeskWidgets.swift -o DeskWidgets
./DeskWidgets
```

Aparece un icono en la barra de menús con **Refresh** y **Quit**. Arrastra los widgets con el ratón para moverlos. Haz clic en un widget o en una fila para abrir su página (uso de Claude, perfil, repo, PR, corrida de CI o servidor local).

Para que arranque al iniciar sesión, copia el binario a una ruta fija, por ejemplo `~/bin/DeskWidgets`, y agrégalo en **Ajustes del Sistema → General → Ítems de inicio**.

## Límites de Claude Code

1. Instala Claude Code: `npm install -g @anthropic-ai/claude-code`.
2. Ejecuta `claude` y haz `/login` con tu cuenta.
3. Abre el widget. macOS pedirá permiso para leer `Claude Code-credentials` del Keychain: elige **Permitir**.

La app lee el token localmente y lo envía únicamente a `api.anthropic.com` para consultar tu uso. Cuando el token vence, lo renueva con el refresh token (en `console.anthropic.com`) y guarda el nuevo en el mismo ítem del Keychain, igual que hace Claude Code. Nunca escribe tokens en logs. Revisa `refreshAccessToken()` y `fetchRealUsageNow()` antes de aceptar.

Si el widget no logra renovar el token por su cuenta, ejecuta `refresh-claude.sh` (junto al binario) como máximo cada 30 minutos. Ese script abre `claude -p` una vez con Haiku y sin `ANTHROPIC_API_KEY`, para que Claude Code renueve su propio login, y se cierra solo (límite de 90 s). Gasta una cantidad mínima de tu suscripción.

Si no hay sesión o falla la consulta, el widget usa los valores manuales de abajo.

## Configuración opcional

Archivo `~/.config/desk-widgets/config.json`:

```json
{
  "plan": "Pro",
  "fiveHourPct": 3,
  "fiveHourReset": "2026-11-02T02:30:00-06:00",
  "weekPct": 64,
  "weekReset": "2026-11-05T09:00:00-06:00",
  "repos": ["~/code/mi-proyecto"]
}
```

`repos` fija qué repos mostrar en Git y Actions. Sin él, detecta los más recientes bajo tu carpeta personal.

## Contribuciones privadas

Para que el contador incluya repos privados, activa **Include private contributions on my profile** en la configuración de contribuciones de tu perfil de GitHub.

## Licencia

MIT
