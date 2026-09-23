# YummyPro — Documento Maestro del Proyecto

> **Fuente de verdad del proyecto.**  
> Última actualización: **23 de septiembre de 2026**.  
> Este documento existe para poder retomar YummyPro aunque se borren conversaciones de ChatGPT.  
> Antes de hacer cambios importantes, leer este archivo y comprobar los repositorios y Supabase.

---

## 1. Propósito de YummyPro

YummyPro nació de la evolución del proyecto Express Delivery hacia una plataforma SaaS multipaís para distintos tipos de negocio.

La visión actual es que una sola plataforma permita administrar negocios con flujos distintos, **sin mezclar información ni módulos entre rubros**.

Tipos de negocio oficiales:

- \`restaurant\` — restaurantes, cafeterías y negocios gastronómicos.
- \`supermarket\` — supermercados.
- \`minimarket\` — minimarkets, tiendas y comercios retail.
- \`professional\` — profesionales y negocios de servicios con agenda/reservas.

### Regla principal de arquitectura

**Nunca mezclar rubros.**

Todo módulo, consulta, permiso, plan, panel, reporte y dato debe filtrarse por:

1. \`restaurant_id\`
2. \`business_type\`
3. rol/permisos del usuario
4. plan/módulos habilitados cuando corresponda

Un restaurante no debe ver módulos retail ni agenda profesional.  
Un supermercado/minimarket no debe heredar cocina o mesas.  
Un profesional no debe heredar pedidos gastronómicos, cocina o QR de mesa.

---

## 2. Repositorios oficiales

### Cliente / menú / tienda / reservas públicas

Repositorio:

- https://github.com/jorge2610g/mipagina

Responsabilidad:

- Menú público de restaurantes.
- Tienda online de supermercados/minimarkets.
- Flujo público de reservas profesionales.
- Cuenta de cliente.
- Carrito, pedidos y seguimiento.
- Pagos del cliente.
- PWA cliente.

Versión visible actual:

- **v1.6.25**

Último commit funcional relacionado con profesionales:

- \`ce702a5b497e98b41876e8c0c7362efefa8ea128\`
- “Agregar reservas públicas para servicios profesionales”

---

### Panel del negocio / restaurante / retail / profesional

Repositorio:

- https://github.com/jorge2610g/yummy-restaurante

Responsabilidad:

- Landing de registro de negocios.
- Panel de restaurante.
- Panel retail.
- Panel profesional.
- POS.
- Caja.
- Cocina.
- Inventario.
- Personal.
- Configuración.
- Suscripciones visibles para el negocio.
- PWA del panel.

Versión visible actual:

- **v2.5.28**

Último commit funcional relacionado con profesionales:

- \`b2de4f28ebf5d98f9ae11908fec0794774a5ec9f\`
- “Conectar agenda profesional a Supabase”

Commits importantes recientes:

- \`b30e5b2d6b623103d284132dcf2e32cd44b7a4ca\` — aislar caja y personal del rubro profesional.
- \`6a77732302f614454f4fd3870997a6b3eb7040fd\` — interfaz y permisos separados para profesionales.
- \`18bcc1c31548039e11ec94ee64333ea8ab68dfe7\` — carga masiva segura restaurante/retail con foto OCR.
- \`a02fe1a55ae00c8ebe30663785d654034e761776\` — imagen demo para productos importados.
- \`4ef6a8b7ac3c3e8bd00b44269e3bb77e0cb599d0\` — acceso administrativo sin volver a pedir credenciales.

Backup importante:

- \`backup/pre-professional-crud-2026-09-23\`

---

### Superadministración

Repositorio:

- https://github.com/jorge2610g/yummy-admin

Responsabilidad:

- Superadmin.
- Perfil 360 de negocios.
- Creación/edición de negocios.
- Planes y suscripciones.
- Pagos de suscripciones.
- Métricas globales.
- Filtros por rubro.
- Acceso administrativo al panel de un negocio.
- Configuración global y control de plataforma.

Versión visible actual:

- **v2.3.30**

Commits importantes recientes:

- \`ceb3aebb29d7667dcdbdc016390604f487b700b8\` — validaciones de calidad del Admin.
- \`cc3f8d44bded45ee670e8ed7d8356b1eacf38b3d\` — seguridad de reservas profesionales.
- \`b5a4f8a570cf825bc843aaf7ec33c7fa1513583e\` — rubro Profesionales + aislamiento por tipo.
- \`85d7598009a79e9c9aae617f9a028253531c54bd\` — respaldo de sesión al abrir panel.
- \`38c47655f7da78acabf459ceb3a7a101160128ca\` — estabilizar puente Abrir panel.

---

## 3. Backend oficial

Proveedor:

- **Supabase**

Proyecto:

- **Express Trinidad Admin**

Project ref:

- \`gulctljitzlwokqydigx\`

Región:

- \`sa-east-1\`

Backend principal:

- PostgreSQL
- Supabase Auth
- RLS
- RPC / funciones SECURITY DEFINER controladas
- Realtime donde corresponde
- Edge Functions para integraciones externas

No guardar claves privadas, service-role keys ni secretos en este documento.

---

## 4. Historia del proyecto

### Fase 0 — Express Delivery / origen

Antes de YummyPro se trabajó en Express Delivery:

- delivery
- pedidos
- pagos
- restaurantes
- landing pages
- paneles
- despliegues
- Mercado Pago
- WhatsApp
- multiubicación
- PWA

Este trabajo fue la base técnica que después evolucionó a YummyPro.

También existió el proyecto Mi Taxi en Trinidad, Bolivia. Comparte aprendizajes de despliegue, PWA, geolocalización, seguridad y multirol, pero **Mi Taxi no forma parte funcional del SaaS YummyPro**.

---

### Fase 1 — Plataforma gastronómica

Se separó el sistema en tres aplicaciones:

1. Cliente.
2. Restaurante.
3. Administración.

Se construyeron los módulos principales de restaurante:

- Dashboard.
- Pedidos.
- Cocina.
- Caja.
- POS Mesero.
- Menú.
- Productos.
- Categorías.
- Variantes/extras.
- QR.
- Clientes.
- Inventario.
- Personal.
- Promociones.
- Reseñas.
- Reportes.
- Configuración.

El objetivo fue que cada rol tuviera únicamente lo que necesita.

---

### Fase 2 — Roles internos

Roles principales del restaurante:

- Administrador local.
- Caja.
- Cocina.
- Mesero.

Reglas:

- Mesero: POS/mesas.
- Cocina: cocina y cambio de estados.
- Caja: caja y cobro.
- Administrador local: acceso completo según plan.
- Superadmin: puede abrir el negocio desde Admin con vista administrativa completa.

Se corrigieron casos donde el menú completo aparecía durante unos instantes antes de aplicar permisos.

---

### Fase 3 — Flujo de pedidos y estados

Estados principales:

- nuevo / recibido
- aceptado
- preparación
- listo
- en camino
- entregado
- cancelado

Reglas históricas acordadas:

- Entregado sale de la lista activa y pasa a Entregados.
- Cancelado pasa a Cancelados.
- Pedidos pagados deben quedar en historial y no permanecer ocupando la vista operativa.
- Cocina controla preparación/listo.
- Caja/POS controla cobro según flujo.
- El administrador puede entregar/cancelar según permisos.
- El cliente recibe cambios de estado.

Filtros:

- día
- semana
- mes
- rango
- estado

---

### Fase 4 — Caja y POS

Se agregó:

- apertura de caja
- cierre
- historial
- responsable de apertura/cierre
- efectivo
- pagos online
- conteo final
- movimientos
- venta diaria

En POS Mesero se trabajó para:

- completar cobro
- retirar pedidos pagados de la pantalla activa
- mantener “Mis pedidos” / historial por fecha
- impedir pedidos operativos cuando la caja esté cerrada cuando el flujo lo requiera

Retail evolucionó a un POS separado, con:

- escáner
- cámara
- productos
- stock
- ticket
- devoluciones
- venta neta

---

## 5. Suscripciones

YummyPro trabaja con planes configurables desde Admin.

Conceptos:

- prueba gratuita
- plan Básico
- plan Estándar/Intermedio
- plan Pro
- planes mensuales
- planes anuales

La prueba gratuita histórica se definió en **30 días**.

Los planes pueden controlar módulos mediante una lista de módulos habilitados.

### Plan anual

Se incorporó soporte para:

- habilitar/deshabilitar anual
- precio anual
- días de acceso
- meses de regalo

Idea comercial definida:

- Básico: 1 mes gratis.
- Estándar: 2 meses gratis.
- Pro: 3 meses gratis.

Admin permite editar:

- nombre
- monto
- duración
- módulos
- estado
- configuración anual

### Regla crítica

Los planes deben estar filtrados por \`business_type\`.

Un negocio solo debe ver planes creados para su rubro.

---

## 6. Pagos

### Pedidos / compras

Pasarela principal:

- Mercado Pago

Reglas:

- Credenciales para pedidos pertenecen al negocio correspondiente.
- Si un negocio no tiene Mercado Pago válido, no mostrar esa opción.
- El cliente debe iniciar sesión cuando el flujo lo exige.
- Al volver desde Mercado Pago, se debe reconciliar el resultado y no quedarse eternamente en “conectando”.
- Solo pedidos aprobados deben tratarse como pagos online confirmados.

Métodos alternativos:

- QR.
- Transferencia.
- Pago móvil/Yape cuando corresponda.
- Otros configurables por país/negocio.

### Suscripciones YummyPro

Los pagos de suscripciones son centralizados:

- usan credenciales de administración/plataforma
- no las credenciales Mercado Pago del restaurante

Se trabajó en:

- pago único
- suscripción recurrente
- verificación
- corte/restricción si corresponde

---

## 7. Multipaís

Se diseñó YummyPro para operar por país.

Configuración por negocio:

- país
- moneda
- locale
- timezone

Monedas usadas o contempladas:

- CLP — Chile
- BOB/Bs — Bolivia
- otras según configuración

Regla:

- Mercado Pago solo debe mostrarse donde esté soportado y configurado.
- En otros países se deben ofrecer métodos alternativos.

---

## 8. Autenticación y separación de tipos de usuario

Se detectó históricamente que cliente, restaurante y administrador podían confundirse porque todos eran usuarios de Auth.

La regla definida es:

- Cliente entra por aplicación cliente.
- Negocio entra por panel del negocio.
- Admin entra por panel Admin.

No se debe asumir que existir en \`auth.users\` autoriza acceso a todas las aplicaciones.

El acceso se controla con:

- pertenencia en tablas correspondientes
- rol
- permisos
- RLS
- verificaciones de aplicación

---

## 9. Superadmin y “Abrir panel”

Una función clave es:

**Admin → Perfil 360 → Abrir panel**

Objetivo:

- abrir directamente el negocio seleccionado
- no volver a pedir usuario/contraseña
- mostrar el nombre del negocio
- dar vista administrativa completa al superadmin
- incluir botón “Volver al admin”

Se hicieron varios hardening/hotfixes porque anteriormente:

- pedía credenciales otra vez
- podía quedar cargando
- se perdía la sesión puente
- algunos módulos quedaban restringidos por plan

Commits relevantes:

Admin:
- \`38c47655f7da78acabf459ceb3a7a101160128ca\`
- \`85d7598009a79e9c9aae617f9a028253531c54bd\`

Panel:
- \`4ef6a8b7ac3c3e8bd00b44269e3bb77e0cb599d0\`
- \`a8ce2cd10bf1c4010528c6dbda7c569aa3cc47ea\`
- \`c78524a7adfcfe4af1f27fad442d3780e933ec82\`

---

## 10. Admin — diseño y navegación

El Admin fue compactado porque con cientos o miles de negocios no es viable mostrar toda la información de una sola vez.

Se implementó/solicitó:

- botones/secciones compactas en móvil
- filtros
- búsqueda
- paginación
- agrupación por tipo de negocio
- métricas
- selector de negocio

Filtro de negocios:

- Restaurantes.
- Supermercados.
- Minimarkets.
- Profesionales.
- Todos.

Regla UX:

No hacer una página enorme que obligue a scrollear indefinidamente.

La misma filosofía aplica a:

- negocios
- suscripciones
- planes
- información detallada

---

## 11. PWA

Se trabajó para convertir las aplicaciones en PWA instalables.

Áreas:

- Admin.
- Panel negocio.
- Cliente.

Problemas tratados:

- Android creaba acceso directo en vez de aplicación.
- Desktop sí instalaba correctamente en algunos casos.
- iconos cuadrados/feos.
- identidad WebAPK.
- manifest.
- service worker.
- caches/versiones.

Cliente alcanzó v1.6.25 y mantiene su PWA.

Precaución:

Cuando cambie una versión relevante, actualizar de forma coherente:

- footer
- manifest/versiones cuando aplique
- service worker/cache
- pruebas estáticas

Evitar cache viejo que haga parecer que un despliegue no se aplicó.

---

## 12. Expansión Retail

YummyPro se amplió a:

- supermercados
- minimarkets
- tiendas

Se crearon módulos específicos:

- Pedidos Online.
- POS Retail.
- Productos Retail.
- Proveedores.
- Compras.
- Caja.
- Personal.
- Configuración.

Funciones retail implementadas:

- catálogo público
- stock real
- carrito
- pedido online
- Mercado Pago
- QR Bolivia
- historial
- seguimiento
- cancelación
- estados en tiempo real
- alertas al negocio
- sonido
- pagos manuales
- dashboard POS + online
- escáner
- cámara
- tickets
- devoluciones
- venta neta

### Regla retail

No usar cocina, mesas ni flujo gastronómico como sustituto del flujo retail.

---

## 13. Carga masiva de productos

Se implementó importación masiva para reducir carga manual.

Objetivo:

- restaurante puede cargar carta/productos masivamente
- supermercado/minimarket puede cargar inventario/productos masivamente

Formatos/ideas trabajadas:

- Excel
- archivos estructurados
- guía XML
- foto/OCR

Commits:

- \`34134c0a1fbbf4f57f80b1e1773cf129cc772ee3\` — Excel + guía XML.
- \`18bcc1c31548039e11ec94ee64333ea8ab68dfe7\` — carga masiva segura + foto OCR.
- \`a02fe1a55ae00c8ebe30663785d654034e761776\` — imagen demo.

Regla:

Los datos importados deben aterrizar en el modelo correspondiente al rubro.

Una carga de supermercado no debe crear estructuras propias del menú restaurante.

Cuando no exista foto, se puede mostrar una imagen demo para mantener estética hasta que el negocio la reemplace.

---

# 14. Rubro Profesionales / Servicios

Esta es la expansión más reciente.

Ejemplos:

- barberías
- peluquerías
- salones
- consultores
- técnicos
- profesionales independientes
- otros servicios con reserva por horario

**No confundir reservas profesionales con reservas de mesa de restaurante.**

---

## 15. Módulos del panel profesional

Módulos definidos:

- Dashboard.
- Agenda / Reservas.
- Servicios.
- Profesionales.
- Clientes.
- Caja.
- Personal.
- Reportes.
- Configuración.

Roles profesionales:

- \`manager\`
- \`professional\`
- \`receptionist\`

Archivo principal separado:

- \`panel/professional.js\`

Versión del módulo:

- YummyPro Profesionales **v2.5.28**

La separación en archivo propio se hizo para no seguir aumentando innecesariamente el enorme \`panel/index.html\`.

---

## 16. Datos profesionales en Supabase

Tablas:

- \`professional_services\`
- \`professional_providers\`
- \`professional_provider_services\`
- \`professional_availability\`
- \`professional_time_off\`
- \`professional_appointments\`

### professional_services

Incluye:

- restaurante/negocio
- nombre
- descripción
- duración
- buffer
- precio
- imagen
- activo
- orden

### professional_providers

Incluye:

- negocio
- usuario opcional
- nombre
- especialidad
- bio
- teléfono
- email
- foto
- activo

### professional_provider_services

Relaciona:

- profesional
- servicio
- negocio

### professional_availability

Define:

- día de semana
- inicio
- fin
- intervalo
- activo

### professional_time_off

Bloqueos:

- vacaciones
- ausencia
- descanso
- otros rangos no disponibles

### professional_appointments

Incluye:

- negocio
- servicio
- profesional
- cliente opcional
- nombre/teléfono/email
- inicio
- fin
- estado
- notas
- método/estado de pago
- depósito
- total

Estados:

- pending
- confirmed
- in_service
- completed
- cancelled
- no_show

---

## 17. Seguridad de agenda profesional

RLS está habilitado.

Políticas internas usan:

- negocio
- \`business_type='professional'\`
- \`is_site_admin()\`
- \`has_restaurant_permission(...)\`

El acceso público no debe tener CRUD directo sobre las tablas profesionales.

Se endurecieron privilegios para dejar acceso directo de tablas al rol autenticado según RLS.

Los clientes públicos trabajan mediante RPC controladas.

Protecciones importantes de base de datos:

- \`professional_appointments_no_overlap\`
- \`professional_appointments_valid_range\`

Esto evita:

- dos citas activas solapadas para el mismo profesional
- rangos inválidos donde fin <= inicio

---

## 18. RPC profesionales

Funciones confirmadas:

- \`create_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text)\`
- \`create_public_professional_appointment(bigint,bigint,bigint,timestamptz,text,text,text,text)\`
- \`get_professional_available_slots(bigint,bigint,bigint,date)\`
- \`get_professional_public_catalog(bigint)\`
- \`get_public_professional_catalog(text)\`

Orden importante de \`get_professional_available_slots\`:

1. \`p_restaurant_id\`
2. \`p_service_id\`
3. \`p_provider_id\`
4. \`p_date\`

No invertir service/provider.

### Cálculo de disponibilidad

Considera:

- servicio asignado al profesional
- horario semanal
- duración
- buffer
- timezone
- aviso mínimo
- máximo de días futuros
- time off
- reservas existentes

Si dos personas intentan tomar el mismo horario, la restricción de DB es la última defensa.

---

## 19. Configuración de reservas profesionales

Se decidió reutilizar columnas existentes en \`restaurants\`.

Campos:

- \`professional_booking_auto_confirm\`
- \`professional_booking_min_notice_hours\`
- \`professional_booking_max_days\`
- \`professional_booking_deposit_required\`
- \`professional_booking_deposit_amount\`

No crear otra tabla de settings salvo que exista un motivo arquitectónico nuevo.

Una tabla temporal \`professional_booking_settings\` fue descartada al descubrir estas columnas.

---

## 20. Flujo público de reservas

Cliente v1.6.25 implementa:

**Servicio → Profesional → Fecha → Hora → Datos cliente → Confirmar**

Datos solicitados:

- nombre
- teléfono
- email opcional
- nota opcional

Muestra:

- servicio
- profesional
- fecha
- hora
- duración
- total
- depósito si corresponde

RPC pública:

- \`create_public_professional_appointment\`

El cliente público no inserta directamente en \`professional_appointments\`.

---

## 21. Flujo interno de agenda

Panel profesional permite:

### Servicios

- crear
- editar
- activar/desactivar
- ordenar/mostrar
- eliminar con validaciones

### Profesionales

- crear
- editar
- activar/desactivar
- asignar servicios
- eliminar con cuidado

### Horario semanal

- días habilitados
- hora inicio
- hora fin
- intervalo
- reemplazo controlado de disponibilidad

### Agenda

- fecha
- estado
- profesional
- crear reserva interna
- listar citas

### Clientes

Se puede derivar historial de clientes a partir de citas.

### Reportes

Métricas implementadas:

- reservas
- completadas
- ingresos
- cancelaciones/no-show
- servicios más reservados

---

## 22. Configuración del panel por rubro

Matriz conceptual:

| Módulo | Restaurante | Supermercado | Minimarket | Profesional |
|---|---:|---:|---:|---:|
| Dashboard | Sí | Sí | Sí | Sí |
| Pedidos gastronómicos | Sí | No | No | No |
| Cocina | Sí | No | No | No |
| POS Mesero | Sí | No | No | No |
| QR Mesa | Sí | No | No | No |
| Productos/Categorías menú | Sí | No | No | No |
| Pedidos online retail | No | Sí | Sí | No |
| POS Retail | No | Sí | Sí | No |
| Proveedores/Compras | No | Sí | Sí | No |
| Agenda/Reservas | No | No | No | Sí |
| Servicios | No | No | No | Sí |
| Profesionales | No | No | No | Sí |
| Clientes | Según flujo | Según flujo | Según flujo | Sí |
| Caja | Sí | Sí | Sí | Sí, adaptada |
| Personal | Sí | Sí | Sí | Sí, adaptado |
| Configuración | Sí | Sí | Sí | Sí |

---

## 23. Menú público según rubro

Cliente detecta:

- \`window.__businessType\`

### professional

Carga:

- \`get_public_professional_catalog\`
- \`get_professional_public_catalog\`

Y renderiza reserva.

### supermarket / minimarket

Carga catálogo retail.

### restaurant

Mantiene menú gastronómico original.

Regla:

La selección de render debe ocurrir temprano para evitar mostrar durante instantes contenido de otro rubro.

---

## 24. Incidencias históricas importantes

Estos problemas ya ocurrieron. Antes de tocar esas zonas, revisar cuidadosamente.

### Panel quedaba en “Cargando”

Hubo regresiones después de cambios en dashboard/permisos.

Se hicieron hotfixes para restaurar carga no bloqueante.

### Mercado Pago / WhatsApp dejaron de responder

Ha ocurrido más de una vez por cambios globales de scripts/UI.

No tocar listeners globales sin probar pagos y WhatsApp.

### “Ver menú” abría lugar equivocado

Desde Admin debe abrir el menú del negocio seleccionado, no Admin.

### Filtros no refrescaban

Hubo problemas en:

- restaurantes
- pedidos
- personal
- selector de negocio
- “Actualizar vista”

### Datos desaparecían tras filtros

Productos/categorías/pedidos parecían desaparecer hasta refrescar.

Evitar mutar el dataset base cuando se aplica un filtro visual.

### “Mis pedidos” pedía login pese a haber sesión

La sesión cliente debe comprobarse antes de mostrar alerta.

### Restricciones de plan bloqueaban superadmin

“Abrir panel” del superadmin debe dar vista administrativa completa del negocio seleccionado.

### PWA Android

Ha sido una zona sensible:

- acceso directo vs instalación
- manifest
- iconos
- WebAPK
- cache

### Load order de professional.js

Actualmente el HTML contiene:

\`<script src="/panel/professional.js?v=2528"></script>\`

antes del gran script inline que declara algunas variables globales como Supabase.

La mayor parte de professional.js usa esos globals al ejecutar funciones más tarde y no de inmediato, por lo que ha funcionado, pero **este orden debe verificarse si aparece un ReferenceError**.

Si falla:

- mover carga del módulo después de inicializar Supabase/globals, o
- envolver inicialización en evento seguro

No cambiarlo sin probar.

---

# 25. ESTADO EXACTO AL 23-09-2026

## Lo que ya funciona o está implementado en código

### Admin

- Profesional aparece como rubro.
- Filtro por rubro.
- Planes separados por rubro.
- Módulos profesionales definidos.
- Perfil de negocio preparado.
- Puente “Abrir panel” endurecido.
- UI móvil compactada.

### Panel

- Navegación profesional.
- Servicios.
- Profesionales.
- Asignación de servicios.
- Horarios.
- Agenda.
- Clientes.
- Reportes.
- Configuración de reservas.
- CRUD conectado a Supabase.
- Separación de roles.
- Caja/personal diferenciados del flujo restaurante.

### Cliente

- Reserva pública profesional.
- Catálogo público.
- Horarios disponibles.
- Creación pública segura de cita.
- v1.6.25.

### Base de datos

- tablas profesionales
- RLS
- RPC
- control de solapamiento
- rango válido
- catálogo público controlado

---

## Bloqueo descubierto justo antes de crear este documento

La función de alta de pruebas:

\`create_my_trial_restaurant_v3\`

todavía contiene una validación antigua:

\`v_business_type not in ('restaurant','supermarket','minimarket')\`

Por eso el frontend muestra **Profesional / Servicios**, pero una cuenta profesional nueva puede ser rechazada por Supabase.

### Cambio pendiente inmediato

Actualizar la función para aceptar:

- \`professional\`

y comprobar que exista un **plan de prueba por defecto** con:

- \`business_type='professional'\`
- activo
- \`is_default_trial=true\`

Después validar:

1. registro desde landing
2. negocio creado como professional
3. restaurant_staff/membresía correcta
4. panel abre Agenda/Dashboard profesional
5. plan visible solo profesional

---

## Estado de datos demo

En la última revisión de base de datos:

- restaurant: 4
- supermarket: 1
- minimarket: 1
- professional: **0**

Por tanto aún faltaba crear un negocio profesional demo real para probar el circuito completo.

### Demo recomendado

Nombre:

- **Barbería Demo YummyPro**

Slug sugerido:

- \`barberia-demo-yummypro\`

País:

- Chile

Timezone:

- America/Santiago

Servicios sugeridos:

1. Corte de cabello — 30 min.
2. Corte + barba — 50 min.
3. Barba — 25 min.

Profesionales:

- Diego Martínez — Barbero.
- Carlos Rojas — Barbero.

Horario demo:

- lunes a viernes
- rango laboral razonable
- intervalos según duración

Prueba final:

**Admin → Abrir panel → Servicios → Profesionales → Horario → Cliente público → Reserva → Agenda → completar/cancelar → Reportes**

---

# 26. Próximos pasos prioritarios

Orden recomendado:

1. Corregir \`create_my_trial_restaurant_v3\` para \`professional\`.
2. Verificar/crear prueba gratuita profesional.
3. Crear negocio profesional demo.
4. Crear servicios.
5. Crear profesionales.
6. Asignar servicios.
7. Crear horarios.
8. Verificar \`get_professional_available_slots\`.
9. Hacer reserva pública real.
10. Confirmar que aparece en Agenda.
11. Cambiar estado.
12. Verificar reportes.
13. Validar cancelación/no-show.
14. Probar aislamiento total con restaurante/retail.
15. Ejecutar pruebas estáticas.
16. Actualizar versiones si se hacen cambios.
17. Actualizar este documento.

---

# 27. Protocolo para retomar en un chat nuevo

Si una conversación se borró o ChatGPT no recuerda el contexto:

### Paso 1

Leer este archivo completo.

### Paso 2

Comprobar los últimos commits de:

- yummy-admin
- yummy-restaurante
- mipagina

### Paso 3

Comprobar versiones visibles en:

- Admin
- Panel
- Cliente

### Paso 4

Verificar Supabase:

- funciones
- tablas
- RLS
- planes
- negocios por business_type

### Paso 5

Buscar la sección:

**ESTADO EXACTO AL 23-09-2026**

y continuar desde los pendientes.

### Paso 6

Después de terminar una etapa:

- actualizar este archivo
- anotar fecha
- versión
- commits relevantes
- migraciones/RPC nuevas
- pendientes

---

# 28. Reglas para futuras modificaciones

1. Hacer backup antes de cambios grandes.
2. No mezclar rubros.
3. No exponer service-role keys.
4. Mantener RLS.
5. Para operaciones públicas usar RPC controladas cuando sea necesario.
6. No confiar solo en el frontend para seguridad.
7. Evitar cambios globales de scripts sin probar pagos/login/PWA.
8. Mantener Admin → Abrir panel.
9. Mantener versiones visibles.
10. Mantener responsive móvil/escritorio.
11. Evitar scroll infinito de paneles administrativos: usar filtros/paginación/secciones.
12. No romper rutas limpias volviendo a introducir \`.html\` donde ya se quitó.
13. Al tocar PWA, revisar manifest + SW + cache + iconos + versión.
14. Al tocar pagos, probar Mercado Pago, métodos alternativos y retorno.
15. Al tocar negocio, probar al menos un ejemplo de cada business_type.

---

# 29. Decisiones de producto que no deben olvidarse

- Diseño profesional, no panel “simple”.
- Móvil y escritorio deben verse bien.
- Los negocios pueden crecer a miles; los filtros son obligatorios.
- El superadmin necesita vista 360.
- Los planes son configurables.
- Los módulos se controlan según plan y rubro.
- El negocio debe entrar al Dashboard y no ser forzado a “Planes” al iniciar.
- Los roles solo deben ver lo que corresponde.
- Cliente debe tener un flujo simple.
- Los estados deben reflejarse en tiempo real cuando corresponda.
- Las cargas masivas deben ahorrar trabajo manual.
- Profesional/Servicios es una vertical independiente, no una adaptación de restaurante.

---

# 30. Convención de actualización de este documento

Cada vez que se complete una etapa importante, agregar al inicio o en “Estado exacto”:

- Fecha.
- Qué se hizo.
- Repositorio.
- Commit.
- Versión.
- Cambios DB.
- Resultado de pruebas.
- Pendiente siguiente.

No borrar historia útil.  
Si una arquitectura cambia, marcar la anterior como obsoleta y explicar la nueva.

---

## Resumen de continuidad

Si solo se puede leer una parte de este documento:

> YummyPro es un SaaS multipaís con tres repositorios (Admin, Panel negocio y Cliente), backend Supabase y cuatro rubros aislados: restaurant, supermarket, minimarket y professional. La expansión profesional ya tiene tablas, RLS, RPC, panel y reserva pública. El siguiente bloqueo conocido es que \`create_my_trial_restaurant_v3\` aún rechaza \`professional\`, y todavía no existe un negocio professional real en la base para hacer la prueba punta a punta. Corregir eso primero y luego ejecutar la prueba completa de Barbería Demo YummyPro.

