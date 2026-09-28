# Estado de releases YummyPro

Actualizado: 2026-09-27

## Regla operativa

- Todo trabajo normal se hace en `staging`.
- `main` no se modifica directamente.
- Producción solo cambia cuando el propietario autoriza **Lanzar a Producción**.
- Después de cada release se comprueba SHA, versión, GitHub Actions, GitHub Pages y backend.
- Los cambios de documentación también se preparan primero en `staging`.

## Último release coordinado

El release coordinado del 2026-09-27 quedó completado y validado en los seis módulos de YummyPro.

Antes de esta actualización documental, `main` y `staging` estaban alineados en los seis repositorios. La única diferencia nueva de Admin es este ajuste de documentación en `staging`; no introduce cambios funcionales ni de base de datos.

## Versiones actuales

| Módulo | Producción (`main`) | Pruebas (`staging`) |
| --- | --- | --- |
| Admin | v2.3.90 | v2.3.90 |
| Restaurante | v2.6.79 | v2.6.79 |
| Retail | v2.5.73 | v2.5.73 |
| Profesionales | v2.5.69 | v2.5.69 |
| Streaming | v1.2.15 | v1.2.15 |
| Cliente | v1.6.63 | v1.6.63 |

## Estado de calidad

El release actual fue promovido con los controles de calidad y despliegue en verde.

En Admin, el Auditor IA volvió a ejecutar correctamente sobre el SHA publicado después del release. Las correcciones antiguas de v2.3.83 que bloqueaban login/panel quedaron superadas y ya no representan el estado actual.

La política vigente sigue siendo estricta: un nuevo release solo puede avanzar cuando el SHA candidato tiene sus controles requeridos actualizados y exitosos.

## Separación de ambientes

- Supabase Pruebas: `wodqqheeesrelsbacmgx`
- Supabase Producción: `gulctljitzlwokqydigx`

La aplicación selecciona el backend según el hostname:
- dominios oficiales `*.yummypro.online` correspondientes → Producción;
- GitHub Pages de Pruebas, localhost y hosts no reconocidos → Staging.

Los releases de código no copian usuarios, pedidos, productos ni otros datos entre ambientes. Las migraciones de base de datos se gestionan de forma explícita y separada.

## Incidentes históricos cerrados

- Se corrigió la selección incorrecta de Supabase Staging en código promovido durante uno de los primeros releases.
- Se endurecieron los gates para exigir `quality`, `smoke`, `environment-guard`, paridad y auditoría correspondiente al SHA candidato.
- Se corrigieron los guards de historial y branch protection del flujo `staging → main`.
- Se corrigieron los fallos de PWA y rutas de Pruebas en los módulos afectados.
- El flujo coordinado de release y realineación posterior de `staging` quedó operativo.

## Estado funcional del último release

- **Admin v2.3.90:** hardening de RPC, telemetría administrativa y control de roles para creación de citas profesionales.
- **Restaurante v2.6.79:** corrección visual para evitar que **Reportar problema** tape el menú lateral.
- **Retail v2.5.73:** corrección del desborde de la etiqueta **Productos** y ajustes visuales del menú.
- **Profesionales v2.5.69:** versión estable publicada con flujo de Pruebas/Producción validado.
- **Streaming v1.2.15:** módulos reales por plan, Marca Blanca PRO, catálogo/operación Streaming y exclusión de Delivery.
- **Cliente v1.6.63:** PWA autocontenida y compatible con la ruta de despliegue de GitHub Pages.

## Próximo ciclo de trabajo

1. Desarrollar cambios nuevos únicamente en `staging`.
2. Mantener `main` sin cambios directos.
3. Ejecutar **Preparar lanzamiento** desde Admin cuando exista un nuevo candidato.
4. Confirmar los seis módulos y sus SHA en verde.
5. Revisar las versiones de esta tabla.
6. El propietario decide si pulsa **Lanzar a Producción**.
7. Tras el release, verificar versión, despliegue, backend y realineación de `staging`.

## Regla de decisión

No usar **Lanzar a Producción** si cualquier módulo tiene `quality`, `smoke`, `environment-guard`, paridad, auditoría visual o despliegue del SHA esperado en rojo, cancelado, pendiente, ausente o desactualizado.
