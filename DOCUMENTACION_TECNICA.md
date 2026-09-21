# Guía técnica · YummyPro Admin

> Documento para mantenimiento humano. Actualizado: 21-09-2026.

## Propósito
Panel de superadministración de YummyPro. Administra restaurantes, planes/suscripciones y vistas globales del negocio.

## Archivos principales
- `panel.html`: panel administrativo y lógica operativa principal.
- `index.html`: entrada/interfaz administrativa según la versión publicada.

Antes de editar, comprobar cuál archivo sirve el dominio y su versión visible; ambos han evolucionado de forma independiente.

## Conceptos principales
### Restaurantes
La vista de restaurante reúne datos del negocio, suscripción y acciones como abrir panel/ver menú. Cuando el superadmin abre un restaurante debe conservarse el contexto del restaurante seleccionado.

### Suscripciones
Campos relevantes en backend:
- `subscription_status`
- `subscription_started_at`
- `subscription_expires_at`
- `subscription_plan`
- `subscription_price`
- `subscription_plan_id`

Funciones JS importantes en `panel.html`:
- `saveSubscriptionChange()`: persiste cambios y escribe historial.
- `sendSubscriptionEmail()`: solicita al backend el correo de activación/renovación.
- `editSubscription()`: edición manual.

### Fechas: regla crítica
No convertir una fecha elegida por el usuario a UTC para volver a obtener el día con `toISOString().slice(0,10)`; eso puede desplazar un día por zona horaria. Mantener la fecha local y solo modificar `subscription_expires_at` cuando el usuario cambió realmente la fecha.

## Planes y módulos
Los planes controlan qué módulos puede usar un restaurante. Un cambio de plan debe mantener coherencia entre plan, duración, precio, estado y módulos habilitados.

## Vista global
Los módulos globales deben respetar el selector “Todos los restaurantes” / restaurante específico. Al añadir un filtro, comprobar que realmente se aplique a la consulta y al render.

## Acceso al panel del restaurante
“Abrir panel” es una vista administrativa y no debe quedar limitada accidentalmente por el plan comercial del restaurante. “Ver menú” debe abrir el menú del restaurante seleccionado, no regresar al admin.

## Pagos
Las suscripciones usan credenciales centrales del administrador. No mezclar estas credenciales con las credenciales de Mercado Pago que cada restaurante usa para cobrar pedidos de clientes.

## Seguridad
- Nunca guardar service-role, tokens de Mercado Pago, Resend o Meta en HTML/JS público.
- Acciones privilegiadas deben resolverse en Supabase/Edge Functions.
- No debilitar RLS para resolver problemas visuales del frontend.

## Regla de cambios
Crear backup de la última versión estable, incrementar versión visible, commit separado y verificar despliegue. En cambios de fechas/pagos/autenticación hacer pruebas específicas antes de publicar.
