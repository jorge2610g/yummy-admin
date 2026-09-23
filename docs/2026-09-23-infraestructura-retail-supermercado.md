# Administración Retail / Supermercado — 2026-09-23

## Respaldo
Rama:
`backup/pre-retail-infra-2026-09-23`

Base exacta:
`2d45b8f590290f81549c5e0f2fcb22b8bf7a552e`

## Cambios administrativos
Versión: v2.3.22.

El administrador ahora reconoce:
- Restaurante
- Supermercado
- Minimarket / Tienda

El formulario de negocio incluye `business_type`.

La lista de negocios muestra el tipo junto al nombre.

## Resumen retail
Se agregó `admin_retail_summary` para mostrar:
- supermercados;
- minimarkets;
- productos retail activos;
- productos con stock bajo;
- ventas retail de los últimos 30 días;
- compras retail de los últimos 30 días.

## Perfil 360 retail
Cuando el negocio es supermercado/minimarket el Perfil 360 usa las tablas retail en vez de las tablas de pedidos de restaurante.

Muestra:
- tipo;
- suscripción;
- productos;
- stock bajo;
- ventas;
- total vendido;
- proveedores;
- compras;
- total comprado;
- estado de caja.

Accesos directos:
- POS Retail;
- Productos Retail;
- Compras;
- Dashboard.

## Base de datos retail
Migraciones aplicadas:
- `retail_supermarket_infrastructure_v1`
- `retail_save_product_rpc_v1`
- `admin_retail_summary_v1`

Tablas:
- `retail_products`
- `retail_suppliers`
- `retail_purchases`
- `retail_purchase_items`
- `retail_sales`
- `retail_sale_items`
- `retail_stock_movements`

Campo nuevo:
- `restaurants.business_type`

Integración con caja:
- `restaurant_cash_movements.retail_sale_id`

## Seguridad
Todas las tablas retail tienen RLS.

Las operaciones críticas se ejecutan mediante RPC con validación de:
- sesión autenticada;
- pertenencia/permisos;
- tipo de negocio;
- caja abierta;
- stock disponible.

Las RPC críticas no son ejecutables por `anon`.

Verificado:
- `retail_save_product`: anon = false
- `retail_complete_sale`: anon = false
- `retail_receive_purchase`: anon = false
- `retail_adjust_stock`: anon = false
- `create_my_trial_restaurant_v3`: anon = false

## Decisiones intencionales
No se modificaron todavía los precios ni los módulos comerciales de los planes.

La infraestructura retail reutiliza los permisos existentes para evitar activar/cobrar funciones nuevas sin definir primero la estrategia de planes.

## Próxima etapa recomendada
1. tickets e impresión;
2. devolución/anulación;
3. cámara para código de barras;
4. reportes de utilidad/margen;
5. lotes/vencimientos;
6. tienda online retail;
7. plan de suscripción específico para retail si corresponde.


## Fase 2 — devoluciones y venta neta

Versión de administrador: `v2.3.23`.

El Perfil 360 retail ahora muestra:
- ventas activas;
- venta neta;
- monto devuelto;
- cantidad de devoluciones;
- stock bajo;
- compras;
- proveedores;
- caja.

La venta neta descuenta `refunded_amount`.

Nuevas estructuras:
- `retail_returns`
- `retail_return_items`
- `retail_sales.refunded_amount`
- `retail_sales.refund_status`
- `restaurant_cash_movements.retail_return_id`

RPC operativas:
- `retail_return_sale_items`
- `retail_void_sale`

Las devoluciones completas marcan la venta como `voided`; las parciales permanecen como ventas completadas con saldo neto reducido.

## Entorno demo
Existe **Minimarket Demo YummyPro** para pruebas desde Perfil 360 → Abrir POS Retail.

Incluye:
- tres productos con código de barra;
- proveedor de ejemplo;
- una caja abierta.

No está asociado a una cuenta de restaurante; se administra desde la vista de superadministrador.


## Respaldo original adicional

Rama:
`backup-original-pre-retail-2026-09-23`

Commit previo a retail:
`2d45b8f590290f81549c5e0f2fcb22b8bf7a552e`

## Fase 3 — administración de tienda online

Versión:
`v2.3.24`

El Perfil 360 retail integra ahora:
- pedidos online activos;
- ventas online;
- ventas POS;
- venta neta total;
- devoluciones POS;
- productos;
- stock bajo;
- proveedores;
- compras;
- caja.

Acciones:
- Pedidos Online;
- POS Retail;
- Productos Retail;
- Ver tienda online;
- Abrir panel.

La lista principal de negocios muestra el enlace público de tienda para supermercado/minimarket igual que el menú público de un restaurante.

## Backend de tienda online

Nuevas migraciones de esta fase:
- `retail_online_store_orders_v1`
- `retail_customer_order_history_v1`
- `retail_veripagos_transactions_v1`
- `retail_online_cash_and_manual_payments_v1`
- `retail_realtime_publication_v1`
- `retail_public_catalog_minimum_stock_v1`

Tablas:
- `retail_online_orders`
- `retail_online_order_items`

Integraciones:
- Mercado Pago por restaurante;
- VeriPagos / QR Bolivia;
- caja;
- inventario;
- Web Push;
- Supabase Realtime.

## Seguridad

Se verificaron permisos:
- catálogo público: anon permitido;
- crear pedido público: anon permitido;
- seguimiento con token: anon permitido;
- cancelación temprana con token: anon permitido;
- cambio de estado de negocio: anon bloqueado;
- historial de cuenta: anon bloqueado;
- liberación interna de stock: authenticated/anon bloqueado, service role únicamente.

Las operaciones públicas sensibles exigen tracking token o recalculan los datos completamente en backend.

## Entorno de prueba

**Minimarket Demo YummyPro** permanece disponible desde el administrador y desde la tienda pública para comprobar la integración completa.
