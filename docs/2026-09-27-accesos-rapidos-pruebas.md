# YummyPro — Accesos rápidos a entornos de Pruebas

Fecha: 27 de septiembre de 2026
Estado: IMPLEMENTADO EN STAGING / PENDIENTE VALIDACIÓN VISUAL Y RELEASE
Repositorio: `jorge2610g/yummy-admin`
Rama: `staging`

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

## Commit funcional

- `731b711e36f29de8e581a5e8e70e2f176ff31794` — `feat(admin): accesos rápidos a entornos de pruebas`

## Seguridad y separación de ambientes

- No se modificó `main`.
- No se modificó Supabase.
- No se copiaron datos entre Pruebas y Producción.
- Los enlaces son navegación externa; no transfieren tokens ni sesiones.
- Los destinos se abren en pestaña nueva.
- El grupo usa `admin-only` para seguir el mismo control visual de opciones exclusivas del superadmin.

## Pendiente inmediato

1. Esperar/confirmar despliegue automático de `yummy-admin-pruebas` desde `staging`.
2. Abrir Admin Pruebas y verificar visualmente el grupo `PRUEBAS` en escritorio y móvil.
3. Probar los seis enlaces y confirmar que cada destino carga el entorno correcto.
4. Revisar los workflows de calidad del SHA actual de `staging`.
5. Si todo pasa, dejar la tarea como VALIDADA. No lanzar a Producción hasta que se decida incluirla en el siguiente release.

## Punto exacto para otra IA

La funcionalidad ya está codificada en `staging`. Si se retoma desde otra conversación, no volver a implementarla. Continuar desde la validación visual/funcional del Admin de Pruebas y CI. Producción sigue sin este cambio.
