# Centro de lanzamientos YummyPro

Este módulo prepara un flujo controlado para promover código desde `staging` (Pruebas) hacia `main` (Producción) en los repositorios de YummyPro.

## Protección principal

- El código del Centro de lanzamientos se desarrolla en una rama `feature/*` y no modifica `main` ni `staging` por sí solo.
- El endpoint de publicación real permanece bloqueado salvo que `YUMMY_RELEASE_ENABLED=true`.
- Nunca se escribe sobre `staging`.
- Nunca se copian usuarios, pedidos, productos ni ningún dato de Supabase.
- Antes de publicar se vuelve a leer el SHA actual de `main` y `staging` de todos los repositorios.
- Solo se permite un avance fast-forward (`main` debe ser ancestro de `staging`). Si hay divergencia, se bloquea el release.
- Antes de mover cualquier `main`, se crea una rama de respaldo con el SHA anterior en todos los repositorios.
- Si una promoción falla a mitad, se intenta restaurar cada `main` que ya fue actualizado.

## Repositorios coordinados

- `jorge2610g/yummy-admin`
- `jorge2610g/yummy-restaurante`
- `jorge2610g/yummy-retail`
- `jorge2610g/yummy-profesionales`
- `jorge2610g/yummy-streaming`
- `jorge2610g/mipagina`

## Variables de entorno

Estas variables se configuran únicamente cuando se decida activar el lanzamiento real:

- `SUPABASE_URL`: URL del Supabase correspondiente al panel Admin desplegado.
- `SUPABASE_ANON_KEY` o `SUPABASE_PUBLISHABLE_KEY`: clave pública del mismo entorno.
- `YUMMY_RELEASE_GITHUB_TOKEN`: token de GitHub de alcance mínimo con permiso de lectura/escritura de Contents en los seis repositorios.
- `YUMMY_RELEASE_ENABLED`: debe ser exactamente `true` para permitir una publicación real.

Mientras `YUMMY_RELEASE_ENABLED` no sea `true`, el Centro de lanzamientos funciona únicamente como diagnóstico y no puede modificar Producción.

## Flujo

1. Abrir **Centro de lanzamientos** desde Admin.
2. Pulsar **Preparar lanzamiento**.
3. Revisar que todos los módulos aparezcan listos y que no exista divergencia.
4. El sistema conserva los SHA observados para detectar cambios de último segundo.
5. Pulsar **Lanzar a Producción** y escribir `LANZAR A PRODUCCION`.
6. Se crean respaldos y luego se promueven solo los repositorios con cambios.

## Lo que este flujo no hace

Este flujo no aplica migraciones de base de datos, no sincroniza Supabase y no copia información entre Pruebas y Producción. Las migraciones deben tener un proceso separado y explícito.
