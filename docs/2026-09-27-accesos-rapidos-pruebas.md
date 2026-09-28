# YummyPro — Accesos rápidos a entornos de Pruebas

Fecha: 27 de septiembre de 2026
Estado: IMPLEMENTADO EN STAGING / LISTO PARA RELEASE SOLO CON GATES DEL HEAD FINAL EN VERDE
Repositorio: `jorge2610g/yummy-admin`
Rama: `staging`
Versión base visible: `2.3.90`

## Objetivo

Permitir que el administrador general entre a los entornos de Pruebas de YummyPro desde un solo lugar, sin buscar ni copiar enlaces manualmente.

## Cambio realizado

Se agregó al menú lateral del Admin un grupo `PRUEBAS`, visible únicamente para elementos con clase `admin-only` (administrador general).

Cada acceso abre su destino en una pestaña nueva con `noopener noreferrer`:

- Admin · Pruebas: `https://jorge2610g.github.io/yummy-admin-pruebas/`
- Restaurante · Pruebas: `https://jorge2610g.github.io/yummy-restaurante-pruebas/`
- Retail · Pruebas: `https://jorge2610g.github.io/yummy-retail-pruebas/`
- Profesionales · Pruebas: `https://jorge2610g.github.io/yummy-profesionales-pruebas/`
- Streaming · Pruebas: `https://jorge2610g.github.io/yummy-streaming-pruebas/`
- Cliente · Pruebas: `https://jorge2610g.github.io/yummy-cliente-pruebas/`

Los seis repositorios de Pruebas cuentan con workflow `deploy-staging-pages.yml` para publicar sus respectivos sitios mediante GitHub Pages.

## Archivos afectados

- `admin-streaming-access.js`
- `docs/2026-09-27-accesos-rapidos-pruebas.md`

El HTML principal del Admin no fue modificado para esta funcionalidad. Los accesos se inyectan desde el módulo JavaScript ya cargado por el panel.

## Historial exacto de implementación y correcciones

- `731b711e36f29de8e581a5e8e70e2f176ff31794` — `feat(admin): accesos rápidos a entornos de pruebas`. Implementación inicial de los seis enlaces.
- `d3e79a724dd0e6650c4437b6ed643f6f03d3153f` — `docs(admin): registrar accesos rápidos de pruebas`. Primera documentación de continuidad.
- El primer workflow de Calidad falló porque los seis enlaces externos heredaban la clase `.tab`; la prueba esperaba 9 pestañas internas y encontró 15 elementos.
- `60b76e143f49b11195d587a46ed5f66571161c7b` — `fix(admin): separar accesos de pruebas de las pestañas internas`. Los accesos externos pasan a usar `admin-test-link`, conservando 9 pestañas internas + 6 enlaces externos.
- El siguiente workflow de Calidad detectó que durante esa corrección se habían eliminado accidentalmente dos comentarios/marcadores que el `static-check` usa para verificar la seguridad del ticket temporal de Streaming.
- `108665c03b7dc6460208fdd30c068edf4b4280ad` — `fix(admin): restaurar marcador de seguridad de vista previa`. Se restauraron exactamente los marcadores de seguridad sin cambiar la lógica funcional.
- Sobre `108665c`, `npm run check`, el workflow `Calidad del panel administrativo` y `Guardar separación Pruebas-Producción` terminaron correctamente. El smoke de GitHub Pages quedó como último gate pendiente de ese SHA antes de este commit documental.

## Seguridad y separación de ambientes

- No se modificó `main` durante el desarrollo.
- No se modificó Supabase.
- No se copiaron datos entre Pruebas y Producción.
- Los enlaces son navegación externa; no transfieren tokens ni sesiones.
- Los destinos se abren en pestaña nueva.
- El grupo usa `admin-only` para seguir el mismo control visual de opciones exclusivas del superadmin.
- Los accesos externos no usan la clase `.tab`; así no interfieren con la navegación interna ni con sus pruebas.
- Se conservaron los marcadores que validan que Streaming usa el ticket temporal de un solo uso y no comparte `access_token` ni `refresh_token` de la sesión principal.

## Criterio obligatorio antes de Release

No promover a Producción mientras algún gate del HEAD final de `staging` esté pendiente o en rojo. Confirmar para el SHA exacto que se va a publicar:

1. `Calidad del panel administrativo` = success.
2. `Smoke GitHub Pages Pruebas` = success.
3. `Guardar separación Pruebas-Producción` / guard de ambiente = success.
4. El Centro de lanzamientos no reporta divergencia inesperada.

Los checks rojos de SHAs anteriores forman parte del historial de corrección y no deben confundirse con el estado del HEAD final.

## Punto exacto para otra IA

La funcionalidad ya está codificada y corregida en `staging`. No volver a implementarla. Revisar primero el HEAD actual y sus workflows. Si los tres gates anteriores están en verde para ese mismo SHA, el siguiente paso es usar el Centro de lanzamientos para promover `staging` a `main`, verificar el despliegue de Producción y luego documentar el SHA de release y la paridad final `main = staging`.
