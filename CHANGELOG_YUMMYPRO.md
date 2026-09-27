## 2.3.85 — 2026-09-27
- El Auditor IA mantiene Gemini y Groq como segunda opinión, pero una valoración subjetiva de IA ya no puede bloquear por sí sola un release.
- El gate sigue siendo estricto con evidencia reproducible de Playwright: pantallas, temas, destellos, desbordes, solapamientos, login, JavaScript, HTTP, rutas y publicación exacta de staging.
- Se afinó el prompt para no confundir telemetría histórica o requests abortados por navegación con un fallo actual si la experiencia terminó correctamente.
- Los hallazgos de IA continúan guardándose completos en el informe para revisión humana.
- Producción no fue modificada.

## 2.3.84 — 2026-09-27
- El Auditor Visual distingue carruseles, pestañas y listas con desplazamiento intencional de un desbordamiento real.
- Se eliminan falsos positivos en tabs y catálogos horizontales sin relajar la detección de controles realmente cortados.
- Producción no fue modificada.

## 2.3.83 — 2026-09-27
- Se corrigió un error de sintaxis en el botón **Ver auditoría** que impedía ejecutar el JavaScript principal: el login y el panel quedaban ocultos y generaban errores secundarios de Streaming y filtros.
- La validación estática ahora compila todos los scripts inline de `index.html` y `admin-streaming-access.js`; un error de sintaxis vuelve a bloquear `quality` antes de publicarse.
- El Centro de Lanzamientos ahora exige por cada módulo `quality`, `smoke` y `environment-guard` con conclusión estricta `success`; ya no acepta controles omitidos, neutrales o faltantes.
- El Auditor IA solo habilita un release si además de terminar correctamente guardó evidencia verificable (capturas/informe).
- Se alineó el nombre visible del modelo con el configurado realmente en GitHub Actions: Gemini 3.5 Flash.
- Se fijó Supabase JS en la versión 2.117.2 con verificación SRI para evitar que una actualización futura del CDN cambie Producción sin pasar por Pruebas.
- Se actualizó el estado operativo documentado de los seis módulos y se dejó constancia de que Admin Pruebas no está listo para release hasta que `quality`, `smoke` y el Auditor IA vuelvan a verde.
- Producción no fue modificada.

## 2.3.82 — 2026-09-26
- El Auditor IA ahora funciona como auditor visual + funcional + técnico de Pruebas.
- Recorre secciones autenticadas, móvil y escritorio, compara modo claro/oscuro, detecta controles cortados o tapados y guarda capturas de carga para detectar destellos de marca.
- Añade reglas de nicho para Streaming (contenido de restaurante/delivery visible se considera fallo).
- Verifica que GitHub Pages corresponda exactamente al SHA actual de staging antes de auditar.
- El Centro de Lanzamientos bloquea Producción si la auditoría no pasó o quedó desactualizada frente a cambios más recientes.
- Producción no fue modificada.

## 2.3.81 — 2026-09-26
- El Centro de lanzamientos comprueba el permiso Pull requests: Read and write antes de crear respaldos o tocar Producción.
- Si el token de GitHub carece de ese permiso, Preparar lanzamiento muestra el permiso exacto faltante y bloquea la publicación de forma segura.
- Se evita el mensaje genérico “Resource not accessible by personal access token”.

## 2.3.80 — 2026-09-26
- El release ya no depende de habilitar Auto-Merge en la configuración del repositorio.
- Supabase ejecuta la promoción en segundo plano con EdgeRuntime.waitUntil y devuelve el control al navegador inmediatamente.
- Cerrar el navegador o perder la conexión ya no detiene el lanzamiento.

## 2.3.79 — 2026-09-26
- El lanzamiento a Producción se entrega a GitHub con auto-merge y continúa aunque se cierre el navegador.
- El panel ya no interpreta un timeout de seguimiento como “Lanzamiento detenido”.
- Se reconoce como sincronizado el árbol publicado aunque main esté esperando la realineación del SHA de staging.

# Changelog YummyPro — Admin

## 2026-09-25/26 — 2.3.67 — Pruebas

- Se reemplazó la confirmación nativa del navegador por una confirmación visible dentro del Centro de Lanzamientos.
- Se añadió progreso real por módulo durante el release: pendiente, código publicado, despliegue en curso y Producción verificada.
- Se muestran porcentaje, tiempo transcurrido, estimación de tiempo restante y cantidad de sitios ya verificados.
- Tras mover `main`, el sistema espera y verifica los checks de despliegue de GitHub Pages antes de marcar el release como completamente verificado.
- Si GitHub Pages tarda más de 90 segundos, el panel informa que el código ya fue actualizado y deja al monitor horario continuar la comprobación.
- La Edge Function `release-center` expone el estado del despliegue de Producción sin modificar datos ni ramas `staging`.
- Este cambio permanece únicamente en `staging` hasta un release explícito.

## 2026-09-25/26 — 2.3.66 — Pruebas

- Se formalizó el flujo **Pruebas → Release → Producción**.
- Se prohibieron cambios directos en `main` durante el desarrollo normal.
- Se documentó separación de Supabase entre Pruebas y Producción.
- Se añadió selección segura del backend por hostname: Producción usa `gulctljitzlwokqydigx`; Pruebas usa `wodqqheeesrelsbacmgx`.
- Se reforzó el control de versión y la obligación de documentar cambios.
- Este cambio permanece en `staging` hasta que el propietario autorice el próximo release.

### Nota operativa
El primer release permitió validar el mecanismo de promoción. La revisión posterior detectó que el código promovido conservaba el endpoint de Supabase Staging. La corrección de enrutamiento por ambiente se hizo únicamente en Pruebas y deberá llegar a Producción mediante un release explícito.
