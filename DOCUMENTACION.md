# Documentación técnica · YummyPro Admin

> Mapa del panel de superadministración. Mantener actualizado cuando cambien módulos, tablas o flujos críticos.

## Archivos principales
- `index.html`: versión principal del administrador con interfaz, estilos y lógica.
- `panel.html`: panel administrativo alternativo/compatibilidad que contiene también la gestión de suscripciones y funciones históricas.
Antes de editar, confirmar cuál URL de producción carga cada archivo. No asumir que ambos están sincronizados.

## Inicio y sesión
`login()`, `restoreSession()` y `enter()` controlan autenticación.
`refreshAll()` actualiza datos globales.
El administrador puede cambiar alcance entre todos los restaurantes y uno específico. Funciones relacionadas: `selectedAdminRestaurant()`, `syncAdminRestaurantScope()`, `changeAdminRestaurantScope()`.

## Restaurantes
`loadRestaurants()` carga el directorio.
`renderRestaurantDirectory()` dibuja la lista.
`openRestaurantProfile()` abre Perfil 360.
`openRestaurantPanel()` entra al panel de un restaurante en modo administrador.
`returnToAdminPanel()` vuelve al administrador.
`saveRestaurant()`, `editRestaurant()`, `deleteRestaurant()` gestionan registros.

## Suscripciones
`loadSubscriptionPlans()` carga planes.
`renderSubscriptionPlans()`, `saveSubscriptionPlan()`, `editSubscriptionPlan()`, `toggleSubscriptionPlan()`, `deleteSubscriptionPlan()` administran planes.
`subscriptionInfo()` y `renderSubscriptions()` presentan el estado por restaurante.
En `panel.html`, `subscriptionDateInputValue()` y `subscriptionExpiryFromLocalDate()` evitan sumar accidentalmente un día por conversiones UTC/local.
`saveSubscriptionChange()` guarda cambios e historial.
`sendSubscriptionEmail()` solicita la notificación automática al restaurante cuando corresponde.
No volver a usar `toISOString().slice(0,10)` como fecha editable de vencimiento sin revisar zona horaria.

## Módulos por plan
`planModuleLabels()`, `selectedPlanModules()`, `setSelectedPlanModules()` y `applySelectedPlanAccesses()` controlan accesos incluidos en cada plan. El administrador completo debe poder entrar al panel del restaurante sin quedar restringido por el plan comercial del local.

## Pagos de suscripción
`verifyRestaurantSubscriptionMercadoPago()` y `paySubscriptionPlan()` participan en pagos de planes. Las suscripciones usan credenciales centrales de administración; los pagos de pedidos del cliente usan configuración del restaurante. No mezclar ambos contextos.

## Personal y roles
`loadStaff()`, `createStaffUser()`, `assignStaff()`, `editStaff()`, `saveAccessModal()`, `removeStaff()`.
Mantener separación entre cuentas de cliente, restaurante/personal y administrador.

## Contenido del restaurante desde Admin
Categorías: `loadCategories()`, `saveCategory()`, `editCategory()`, `deleteCategory()`.
Productos: `loadProducts()`, `saveProduct()`, `editProduct()`, `toggleProduct()`, `deleteProduct()`.
Inventario: `loadAdminInventory()`.
Promociones: `loadAdminPromotions()`, `saveAdminPromotion()`.
Reseñas: `loadAdminReviews()`, `respondAdminReview()`.
Clientes: `loadAdminCustomers()`.
Cocina/finanzas: `loadAdminKitchen()`, `loadAdminFinance()`.

## Pedidos
`loadOrders()`, `filterOrdersView()`, `filterOrdersStatus()`, `openOrderTimeline()`, `setOrderStatus()`, `printOrderCommand()`.
Los filtros deben respetar el restaurante seleccionado en el alcance global.

## Dashboard
`loadAdminDashboardMetrics()`, `renderAdminMetrics()`, `renderBusinessStatus()`, `formatSubscriptionCountdown()`.
No mostrar métricas internas antes de autenticar.

## Seguridad
- Nunca guardar claves privadas o service-role en el frontend.
- Crear backup antes de cambios.
- Incrementar versión visible por cada cambio de código.
- Verificar Admin Full y un restaurante con plan limitado.
- Probar filtros con “Todos los restaurantes” y restaurante individual.
- Mantener historial de cambios de suscripción.
- Para fechas, probar zona horaria de Chile/Bolivia además de UTC.

## Regla para archivos duplicados
Si una función existe en `index.html` y `panel.html`, no copiar cambios a ciegas. Comparar primero porque las versiones pueden tener diferencias funcionales.
