# YummyPro — Panel central de accesos Pruebas / Producción

Fecha: 27 de septiembre de 2026
Estado: IMPLEMENTADO Y VALIDADO EN STAGING / LISTO PARA RELEASE TRAS VERIFICAR EL HEAD DOCUMENTAL FINAL
Repositorio: `jorge2610g/yummy-admin`
Rama: `staging`
Versión base visible: `2.3.90`

## Objetivo

Permitir al administrador general cambiar fácilmente entre los entornos de YummyPro sin llenar el menú hamburguesa con múltiples enlaces.

## Diseño vigente

El diseño inicial con seis accesos externos visibles directamente en el menú lateral fue reemplazado.

Ahora el menú lateral contiene un único botón:

- En Producción: `Acceso a Pruebas`.
- En Admin Pruebas: `Acceso a Producción`.

Al tocar ese botón no se navega todavía a otro sitio. Se abre una sección dentro del mismo panel Admin, igual que las demás secciones internas. Esa sección muestra seis tarjetas/botones:

- Admin
- Restaurante
- Retail
- Profesionales
- Streaming
- Cliente

Recién al tocar una de esas tarjetas se abre el destino externo en una pestaña nueva con `target="_blank"` y `rel="noopener noreferrer"`.

En móvil se mantiene exactamente el mismo flujo: un solo botón en el hamburguesa y los seis destinos dentro del contenido principal.

## Comportamiento reversible por ambiente

El panel detecta el ambiente del Admin.

### Desde Producción

Muestra accesos hacia Pruebas:

- Admin: `https://jorge2610g.github.io/yummy-admin-pruebas/`
- Restaurante: `https://jorge2610g.github.io/yummy-restaurante-pruebas/`
- Retail: `https://jorge2610g.github.io/yummy-retail-pruebas/`
- Profesionales: `https://jorge2610g.github.io/yummy-profesionales-pruebas/`
- Streaming: `https://jorge2610g.github.io/yummy-streaming-pruebas/`
- Cliente: `https://jorge2610g.github.io/yummy-cliente-pruebas/`

### Desde Admin Pruebas

Muestra accesos de regreso a Producción:

- Admin: `https://admin.yummypro.online/`
- Restaurante: `https://web.yummypro.online/`
- Retail: `https://retail.yummypro.online/`
- Profesionales: `https://pro.yummypro.online/`
- Streaming: `https://streaming.yummypro.online/`
- Cliente: `https://menu.yummypro.online/`

## Ubicación y navegación

El botón intenta colocarse inmediatamente después de la opción `Lanzar Producción`. Si esa opción no se encuentra por texto, usa como fallback el final del grupo de navegación.

El botón de ambiente no usa la clase `.tab`, por lo que no altera el conteo de las 9 pestañas internas esperado por las pruebas actuales. La vista `adminEnvironmentAccess` sí se comporta como una sección interna y desactiva las demás secciones al abrirse.

## Archivos afectados

- `admin-streaming-access.js`
- `docs/2026-09-27-accesos-rapidos-pruebas.md`

El HTML principal `index.html` no fue modificado para esta funcionalidad.

## Historial exacto

- `731b711e36f29de8e581a5e8e70e2f176ff31794` — implementación inicial con seis enlaces directos en el menú.
- `d3e79a724dd0e6650c4437b6ed643f6f03d3153f` — documentación inicial.
- El primer workflow de Calidad falló porque los seis enlaces heredaban `.tab`: se esperaban 9 pestañas y se encontraron 15.
- `60b76e143f49b11195d587a46ed5f66571161c7b` — separación de los enlaces externos respecto de `.tab`.
- Durante esa corrección se eliminaron accidentalmente marcadores de seguridad de Streaming que usa el `static-check`.
- `108665c03b7dc6460208fdd30c068edf4b4280ad` — restauración de los marcadores de ticket temporal y no compartición de tokens.
- `5fc5e2c93cdad0a995dd1539df52636d62c9704d` — documentación del estado validado del diseño anterior.
- `ddbe6abb7dedb245deb03b8786816fe2b0e65d05` — diseño vigente: reemplaza los seis enlaces del hamburguesa por un único botón y una vista interna reversible Pruebas / Producción.
- `8a75e71b0c0617a6806ec7dda17fcb683e0d22dd` — documentación del diseño vigente y SHA validado funcionalmente.
- `yummy-admin-pruebas` commit `a5cd272287117ada9ddf9fb5f2b4624d4d5090a2` publicó Admin Pruebas tomando como source `8a75e71b0c0617a6806ec7dda17fcb683e0d22dd`.

## Validaciones confirmadas sobre `8a75e71`

- `Guardar separación Pruebas-Producción` = **success**.
- `Smoke GitHub Pages Pruebas` = **success**.
- `Calidad del panel administrativo` = **success**.
- Dentro de Calidad: `npm run check` = **success** y `npx playwright test tests/admin.spec.js` = **success**.
- Publicación `Publicar Admin Pruebas` = **success**.

Los checks verdes anteriores a `ddbe6ab` corresponden al diseño anterior y no deben usarse como evidencia del diseño vigente. La evidencia válida funcional es la de `8a75e71` y cualquier HEAD posterior que solo cambie esta documentación debe volver a comprobar sus gates antes de release.

## Seguridad y separación de ambientes

- `main` no se modifica durante el desarrollo.
- No se modifica Supabase.
- No se copian datos entre Pruebas y Producción.
- Los accesos externos no transfieren tokens ni sesiones.
- Los destinos se abren en pestaña nueva con `noopener noreferrer`.
- El botón mantiene la clase `admin-only` y además valida `isSuperAdmin` al abrir la vista.
- Streaming conserva los marcadores que verifican el uso del ticket temporal de un solo uso y que no se comparte `access_token` ni `refresh_token` de la sesión principal.

## Criterio obligatorio antes de Release

No promover a Producción hasta que, sobre el mismo HEAD final de `staging`, estén en verde:

1. `Calidad del panel administrativo`.
2. `Smoke GitHub Pages Pruebas`.
3. `Guardar separación Pruebas-Producción` / environment guard.
4. Publicación de Admin Pruebas con el mismo SHA de `staging` que se está validando.
5. Verificación de que no exista divergencia inesperada antes del release.

## Punto exacto para otra IA

No volver al diseño de seis botones visibles en el hamburguesa. El requisito vigente es **un solo botón de ambiente + una sección interna con seis destinos** y comportamiento reversible: Producción → Pruebas, Admin Pruebas → Producción.

El código funcional quedó en `ddbe6ab`; `8a75e71` fue validado con todos los gates en verde. Este archivo se actualizó después para registrar esas evidencias, por lo que la siguiente IA debe mirar el HEAD de `staging` y comprobar que los gates del HEAD documental final también estén verdes. Si están verdes, puede prepararse el release; tras promover, verificar `main = staging` y documentar el SHA final de Producción.

## Incidencia previa al release · Auditor IA

Al preparar el release del panel central de ambientes se detectó que el Centro de lanzamientos rechazaba el lanzamiento con el mensaje de que el Auditor IA no correspondía al SHA actual de Admin Pruebas.

Causa confirmada: el workflow `Auditor IA de Pruebas` no se ejecuta ante cambios en `admin-streaming-access.js` ni ante cambios únicamente documentales. Sus ejecuciones programadas se estaban resolviendo sobre `main`, cuyo SHA seguía siendo `0fca9afb2afaf377553cacdd1443d2fb7b767f18`, mientras `staging` ya estaba en `7a8520a16f98c1adf33f0d0fad5778cfe3efcf56`.

Resolución aplicada: documentar la incidencia, actualizar `.ai-audit-trigger` en `staging` para obligar una auditoría sobre el HEAD final y publicar ese mismo SHA exacto en `yummy-admin-pruebas`. No promover a Producción hasta que Auditor IA, Calidad, Smoke y guard de ambiente estén en verde para el mismo HEAD.
