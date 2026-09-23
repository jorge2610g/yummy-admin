# Admin móvil, filtros y planes por tipo de negocio — 2026-09-23

## Respaldo
Antes de esta etapa se creó:
`backup/pre-admin-mobile-filters-2026-09-23`

La copia original anterior a Retail continúa intacta:
`backup-original-pre-retail-2026-09-23`

## Versión
Administrador: `v2.3.25`.

## Navegación móvil por bloques
En móvil se agregaron botones para evitar mostrar toda la información de una sola vez.

### Dashboard
- Resumen
- Accesos
- Actividad
- Diagnóstico

### Negocios
- Resumen
- Negocios

### Suscripciones
- Planes
- Suscripciones
- Historial
- Métodos de cobro

El bloque **Métodos de cobro** agrupa:
- Mercado Pago
- Flow Chile
- QR Bolivia / VeriPagos

### Configuración
- Datos
- Marca
- Delivery / Estado
- Pagos

En escritorio se mantiene la visualización completa.

## Filtros y paginación
Se agregaron filtros por tipo de negocio:
- Restaurante
- Supermercado
- Minimarket / Tienda
- Todos

Se aplicaron en:
- Negocios
- Suscripciones
- Historial de pagos de suscripción
- Personal
- Clientes

También se agregó filtro por negocio específico donde corresponde.

Para evitar scroll infinito se agregó paginación a:
- Negocios
- Suscripciones
- Historial de pagos
- Personal
- Clientes

El tamaño inicial es de 20 registros por página; historial usa 25.

## Historial de pagos
Filtros:
- tipo de negocio;
- negocio;
- estado;
- proveedor.

Estados:
- aprobado / pagado;
- pendiente / en proceso;
- rechazado;
- cancelado;
- reembolsado;
- pausado.

Proveedores:
- Mercado Pago;
- Flow;
- QR Bolivia / VeriPagos.

## Planes por tipo de negocio
`subscription_plans` ahora incluye:
`business_type`

Valores:
- `restaurant`
- `supermarket`
- `minimarket`

Los planes existentes quedaron como `restaurant`.

Cada tipo de negocio tiene su propia prueba predeterminada de 30 días.

### Módulos de Restaurante
Se conserva el esquema anterior:
Dashboard, Productos, Categorías, QR, QR de Mesa, Configuración, Pedidos, Meseros/POS, Caja, Cocina, Inventario, Personal, Promociones, Reseñas y WhatsApp Bot.

### Módulos de Supermercado / Minimarket
- Dashboard
- Pedidos Online
- POS Retail
- Productos Retail
- Proveedores
- Compras
- Caja
- Personal
- Configuración

Al crear o editar un plan el administrador selecciona primero el tipo de negocio y después activa/desactiva los módulos correspondientes.

## Seguridad de suscripciones
Se agregó validación en backend:
- un restaurante solo puede recibir un plan de restaurante;
- un supermercado solo puede recibir un plan de supermercado;
- un minimarket solo puede recibir un plan de minimarket;
- los pagos de suscripción también validan la coincidencia entre plan y tipo de negocio.

## Clientes
El listado de clientes combina actividad de:
- pedidos de restaurante;
- pedidos online Retail.

Un cliente puede aparecer asociado a más de un tipo de negocio y los filtros permiten aislar la categoría deseada.

## Personal
El personal se puede filtrar por:
- tipo de negocio;
- negocio específico;
- correo/rol.

## Base de datos
Migraciones aplicadas:
- `subscription_plans_by_business_type_v1`
- `align_existing_retail_trials_v1`
- `enforce_subscription_business_type_v1`
- `subscription_business_type_integrity_v1`

## Rollback
Frontend:
usar `backup/pre-admin-mobile-filters-2026-09-23`.

Estado original anterior a Retail:
usar `backup-original-pre-retail-2026-09-23`.

La migración de planes es estructural y aditiva. Antes de retirar `business_type` se deben revisar planes y suscripciones creadas para Retail.
