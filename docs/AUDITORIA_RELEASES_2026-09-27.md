# Auditoría de releases — 2026-09-27

## Alcance

Revisión de `jorge2610g/yummy-admin`, rama `staging`, con foco en documentación, separación Pruebas/Producción, seguridad y gates automáticos de publicación.

## Hallazgos confirmados y corregidos en v2.3.83

1. **JavaScript principal roto.** Un `onclick` generado con comillas inválidas producía `SyntaxError: Unexpected identifier '_blank'`. El navegador no llegaba a inicializar Supabase, el login ni el panel.
2. **El análisis estático no compilaba el JavaScript del HTML.** Solo comprobaba que ciertos textos existieran. Ahora compila todos los scripts inline y el archivo de integración Streaming.
3. **El release no exigía `smoke`.** El backend comprobaba únicamente el check llamado `quality`, aunque la política escrita exige `quality` y `smoke`. Ahora cada módulo requiere `quality`, `smoke` y `environment-guard` con conclusión exacta `success`.
4. **Resultados débiles podían aprobar.** `neutral` y `skipped` se aceptaban como correctos. Ya no habilitan Producción.
5. **El Auditor IA podía aprobar sin evidencia.** Ahora debe guardar al menos un artefacto con capturas/informe, además de corresponder a los SHA vigentes.
6. **Dependencia flotante.** El navegador cargaba `@supabase/supabase-js@2`, que podía cambiar sin commit ni pruebas. Se fijó 2.117.2 y se añadió integridad SRI.
7. **Documentación desactualizada.** `RELEASE_STATUS.md` describía versiones antiguas y una incidencia ya cerrada. Se actualizó con el estado real observado.
8. **Nombre de modelo inconsistente.** La interfaz decía Gemini 3.8 Flash, mientras el workflow ejecuta `gemini-3.5-flash`. Se alineó la interfaz con la configuración real.

## Estado observado antes de la corrección

- Admin `staging` en v2.3.82: `quality`, `smoke` y `ai-audit` en rojo.
- Los seis módulos presentaban un `smoke` reciente en rojo.
- `environment-guard` estaba verde.
- Producción no fue modificada durante esta auditoría.

## Riesgos pendientes

1. Los repositorios Restaurante, Retail, Profesionales, Streaming y Cliente deben auditarse individualmente para explicar y corregir sus `smoke` rojos; el nuevo gate impedirá publicarlos mientras tanto.
2. La clave pública de Google Maps incluida en el frontend debe permanecer restringida en Google Cloud por dominios autorizados y API concreta. Una clave de navegador es visible por diseño, pero no debe aceptar orígenes arbitrarios.
3. El proceso de release depende de que las reglas de protección de `main` requieran los checks correctos. Debe verificarse esa configuración en GitHub para los seis repositorios.
4. Las migraciones y políticas RLS deben validarse en Staging con los Advisors de Supabase antes del siguiente cambio de esquema. Esta revisión del repositorio no sustituyó una auditoría conectada de la base de datos.

## Condición para publicar

No lanzar a Producción hasta que, para cada SHA candidato, estén verdes `quality`, `smoke`, `environment-guard`, la paridad que corresponda y el Auditor IA con evidencia. Después del release deben comprobarse SHA, versión, despliegue y backend seleccionado por hostname.
