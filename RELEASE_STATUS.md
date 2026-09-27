# Estado de releases YummyPro

Actualizado: 2026-09-27

## Regla operativa

- Todo trabajo normal se hace en `staging`.
- `main` no se modifica directamente.
- Producción solo cambia cuando el propietario autoriza **Lanzar a Producción**.
- Después de cada release se comprueba SHA, versión, GitHub Actions, GitHub Pages y backend.

## Versiones actuales

| Módulo | Producción (`main`) | Pruebas (`staging`) |
| --- | --- | --- |
| Admin | v2.3.81 | v2.3.83 |
| Restaurante | v2.5.75 | v2.5.75 |
| Retail | v2.5.69 | v2.5.69 |
| Profesionales | v2.5.69 | v2.5.69 |
| Streaming | v1.2.10 | v1.2.13 |
| Cliente | v1.6.63 | v1.6.63 |

## Estado de calidad de Pruebas

Estado observado para el último commit de Admin Pruebas antes de v2.3.83:
- `environment-guard`: verde.
- `quality`: rojo.
- `smoke`: rojo.
- `Auditor IA`: rojo.

La causa principal confirmada fue un error de sintaxis en `index.html` que detenía el JavaScript principal y dejaba ocultos tanto el login como el panel. La corrección está en v2.3.83 y debe volver a ejecutar todos los gates. Hasta que los tres controles estén verdes, **Admin no está listo para Producción**.

## Separación de ambientes

- Supabase Pruebas: `wodqqheeesrelsbacmgx`
- Supabase Producción: `gulctljitzlwokqydigx`

La versión preparada en `staging` selecciona el backend según el hostname:
- dominios oficiales `*.yummypro.online` correspondientes → Producción;
- GitHub Pages de Pruebas, localhost y hosts no reconocidos → Staging.

## Incidentes históricos cerrados

El primer release dejó temporalmente el endpoint de Supabase Staging fijo en el código promovido. La selección por hostname ya forma parte de las versiones actuales. Los controles deben seguir verificándola en cada release para impedir una regresión.

## Próximo release

Antes de liberar:
1. Abrir Admin Pruebas.
2. Ejecutar **Preparar lanzamiento**.
3. Confirmar los seis módulos en verde.
4. Revisar las versiones de esta tabla.
5. El propietario decide si pulsa **Lanzar a Producción**.
6. Tras el release, el monitor horario verificará que `main = staging`, que las versiones coincidan y que cada dominio use su Supabase correcto.

## Regla de decisión

No usar **Lanzar a Producción** si cualquier módulo tiene `quality`, `smoke`, paridad, auditoría visual o despliegue del SHA esperado en rojo, cancelado, pendiente o desactualizado.
