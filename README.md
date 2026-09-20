# YummyPro — Panel Administrativo Global

## Propósito
Panel del administrador general de la plataforma. Permite administrar restaurantes, usuarios, planes/suscripciones, accesos, métricas y consultar la operación por restaurante.

## Cambios implementados hasta 20-09-2026
- Separación de acceso por rol: solo administradores pueden utilizar este panel.
- Pantalla de login aislada: métricas/actividad no deben mostrarse antes de autenticar.
- Correcciones del arranque móvil y errores JavaScript que dejaban el panel vacío.
- Gestión de restaurantes: activar/suspender, editar y Perfil 360°.
- Perfil 360° con accesos a información del restaurante.
- Selector de restaurante para consultar módulos/actividad por local.
- Resumen global para “Todos los restaurantes” y resumen filtrado por restaurante.
- Gráficas de últimos 7 días y actividad reciente limitadas al Resumen; no se repiten innecesariamente en otros módulos.
- Módulos administrativos para pedidos, clientes, cocina, caja/pagos, inventario, promociones, reseñas, productos, categorías, QR y personal.
- Filtros por restaurante en módulos operativos.
- Pedidos online: enfoque en pagos Mercado Pago aprobados.
- Cocina separada de pedidos online; pedidos de mesa pueden identificar al mesero responsable.

## Planes y suscripciones
- Creación/edición de planes con nombre, precio, duración y módulos.
- Módulos guardados en `subscription_plans.modules`.
- Configuración de restaurante mediante popup: plan, precio pagado, días restantes, vencimiento, accesos especiales y notas.
- Al elegir un plan en la configuración del restaurante se precargan/marcan automáticamente sus módulos.
- Se conservan controles de activar/suspender.
- Los accesos especiales permiten ajustar un restaurante sin modificar el plan general.
- La prueba de 30 días contempla accesos básicos del menú.

## Mercado Pago de suscripciones
- Las suscripciones y pagos de planes utilizan exclusivamente las credenciales centrales del administrador/Express.
- Las credenciales Mercado Pago propias de cada restaurante se reservan para cobrar pedidos de sus clientes.
- Existen flujos separados para pago único de plan y suscripción recurrente.
- La lógica backend se apoya en Edge Functions/Supabase; nunca deben exponerse Access Tokens en el navegador.

## Versionado y rollback
Cada cambio funcional se registra en un commit. La versión visible del frontend se incrementa para comprobar si el hosting publicó el código nuevo.

## Repositorios relacionados
- Cliente/menú: `jorge2610g/mipagina`
- Restaurante/landing/panel: `jorge2610g/yummy-restaurante`

## Importante
No documentar ni subir contraseñas, Access Tokens, Service Role Keys u otros secretos.
