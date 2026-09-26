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
