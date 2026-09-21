# Guía del código · YummyPro Admin

## Propósito
Panel de superadministración de YummyPro. Administra restaurantes, planes, suscripciones, pedidos y vistas globales.

## Archivo principal
- `panel.html`: interfaz y lógica del panel administrativo.
- `index.html`: entrada/login y/o vistas asociadas según la versión publicada.

## Conceptos principales
El administrador trabaja sobre múltiples restaurantes. Los filtros deben conservar el restaurante seleccionado y nunca mezclar datos entre negocios.

### Restaurantes
El perfil 360 reúne datos del restaurante. “Abrir panel” debe entrar en contexto del restaurante seleccionado con vista administrativa completa; “Ver menú” debe abrir el menú de ese restaurante.

### Suscripciones
Funciones de edición actualizan plan, precio, estado y vencimiento. Las fechas deben tratarse como fecha local cuando se editan desde inputs `date`; evitar convertir primero con UTC porque puede sumar/restar un día.

`saveSubscriptionChange()` guarda el cambio y el historial. Las activaciones/renovaciones manuales llaman `restaurant-email-notifications`.

### Planes
Los planes definen duración, precio y módulos. Los módulos habilitados condicionan el panel restaurante. No confundir permisos del plan con rol del personal.

### Pagos
Las suscripciones usan credenciales centrales del administrador. Los pagos de pedidos pertenecen al restaurante y no deben reutilizar credenciales globales indebidamente.

## Seguridad
No poner service-role, tokens de Mercado Pago, Resend ni Meta en HTML/JS. Las acciones privilegiadas deben resolverse mediante Supabase/RPC/Edge Functions con autorización.

## Reglas para cambios
1. Backup del último commit estable.
2. Incrementar versión visible.
3. Commit por cambio.
4. Probar filtros con “Todos” y un restaurante específico.
5. Probar suscripciones: activar, editar sin cambiar fecha, cambiar fecha, renovar y vencer.
6. Verificar móvil/escritorio y no afirmar despliegue sin comprobarlo.

## Diagnóstico
Si un filtro no actualiza, comprobar estado del selector, consulta Supabase y render posterior. Si la fecha cambia un día, buscar conversiones `toISOString().slice(0,10)` sobre fechas locales. Si “Abrir panel” restringe módulos, revisar el modo de previsualización administrativa.
