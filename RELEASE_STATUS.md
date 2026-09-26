# Estado de releases YummyPro

Actualizado: 2026-09-25/26

## Regla operativa

- Todo trabajo normal se hace en `staging`.
- `main` no se modifica directamente.
- Producción solo cambia cuando el propietario autoriza **Lanzar a Producción**.
- Después de cada release se comprueba SHA, versión, GitHub Actions, GitHub Pages y backend.

## Versiones actuales

| Módulo | Producción (`main`) | Pruebas (`staging`) |
| --- | --- | --- |
| Admin | v2.3.64 | v2.3.66 |
| Restaurante | v2.5.72 | v2.5.73 |
| Retail | v2.5.66 | v2.5.67 |
| Profesionales | v2.5.66 | v2.5.67 |
| Streaming | v1.2.7 | v1.2.8 |
| Cliente | v1.6.53 | v1.6.54 |

## Estado de calidad de Pruebas

Los seis módulos tienen:
- `environment-guard` en verde.
- `quality` en verde.
- `smoke` en verde.

## Separación de ambientes

- Supabase Pruebas: `wodqqheeesrelsbacmgx`
- Supabase Producción: `gulctljitzlwokqydigx`

La versión preparada en `staging` selecciona el backend según el hostname:
- dominios oficiales `*.yummypro.online` correspondientes → Producción;
- GitHub Pages de Pruebas, localhost y hosts no reconocidos → Staging.

## Anomalía detectada tras el primer release

La primera promoción `staging → main` copió correctamente el código, pero ese código todavía tenía el endpoint de Supabase Staging fijo. Como resultado, la versión que quedó en `main` conserva actualmente la referencia de Staging.

**No se corrigió `main` directamente**, respetando la regla de no tocar Producción.

La corrección ya está implementada y probada en `staging`. Llegará a Producción únicamente cuando el propietario autorice el próximo release.

## Próximo release

Antes de liberar:
1. Abrir Admin Pruebas.
2. Ejecutar **Preparar lanzamiento**.
3. Confirmar los seis módulos en verde.
4. Revisar las versiones de esta tabla.
5. El propietario decide si pulsa **Lanzar a Producción**.
6. Tras el release, el monitor horario verificará que `main = staging`, que las versiones coincidan y que cada dominio use su Supabase correcto.
