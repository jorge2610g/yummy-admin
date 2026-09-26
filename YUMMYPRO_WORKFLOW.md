# Política de trabajo YummyPro — Admin

## Regla principal

**Producción no se modifica directamente.** Todo cambio normal de código, diseño, funciones, pruebas, correcciones o documentación se realiza en la rama `staging`.

La rama `main` representa Producción y solo puede avanzar mediante el proceso de **Lanzar a Producción** después de una decisión explícita del propietario.

- Repositorio: `jorge2610g/yummy-admin`
- Pruebas: `staging`
- Producción: `main`
- URL Pruebas: https://jorge2610g.github.io/yummy-admin-pruebas/
- URL Producción: https://admin.yummypro.online

## Ambientes de datos

El código puede ser idéntico entre `staging` y `main`, pero los datos no se mezclan.

- Supabase Pruebas: `wodqqheeesrelsbacmgx` (YummyPro Staging)
- Supabase Producción: `gulctljitzlwokqydigx`
- Solo el hostname oficial de Producción puede seleccionar el backend de Producción.
- GitHub Pages de Pruebas, localhost y hosts no reconocidos deben usar el backend de Pruebas.

Nunca copiar usuarios, pedidos, clientes, inventario ni datos de pruebas hacia Producción como parte de un release.

## Release

1. Trabajar únicamente en `staging`.
2. Actualizar versión y documentación.
3. Esperar `quality` y `smoke` en verde.
4. Preparar lanzamiento desde Admin Pruebas.
5. El propietario decide cuándo pulsar **Lanzar a Producción**.
6. El release mueve código `staging → main` con respaldo previo.
7. Después del release verificar SHA, versión, GitHub Pages y backend de ambos ambientes.

Durante desarrollo es normal que `staging` esté por delante de `main`. Es anómalo que `main` esté por delante o que las ramas diverjan.

## Versiones

La versión fuente de este módulo está en el archivo `VERSION` y debe coincidir con la versión visible de la aplicación cuando exista.

- Cambio visible o funcional: incrementar al menos el patch.
- Registrar cada cambio en `CHANGELOG_YUMMYPRO.md`.
- No reutilizar un número de versión para código diferente.
- Un release debe permitir comprobar qué versión está en Pruebas y cuál llegó a Producción.

## Documentación obligatoria

Cada cambio debe dejar constancia en `CHANGELOG_YUMMYPRO.md` indicando qué cambió, por qué y si está pendiente de release.

Esta política tiene prioridad operativa: si una tarea no dice explícitamente “Producción” o “release”, se trabaja en `staging`.
