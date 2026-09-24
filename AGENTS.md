# AGENTS.md — Reglas de desarrollo de YummyPro Admin

Estas reglas aplican a cualquier agente de IA o desarrollador que modifique este repositorio.

## Objetivo

Mantener el panel administrativo global de YummyPro estable, rápido, seguro y fácil de mantener.

Repositorio relacionado:
- Admin: `jorge2610g/yummy-admin`
- Restaurante / landing: `jorge2610g/yummy-restaurante`
- Cliente / menú: `jorge2610g/mipagina`

Antes de cambiar algo, identifica si realmente pertenece a este repositorio. No mezcles lógica del cliente o del panel de negocio dentro del administrador global.

---

## 1. Pensar antes de modificar

- Inspecciona primero el flujo existente, funciones relacionadas y dependencias.
- No asumas nombres de tablas, columnas, rutas, funciones RPC, Edge Functions o roles: verifícalos.
- Si hay dos interpretaciones posibles y una puede romper datos o seguridad, detente y aclara.
- Si la intención se puede resolver con seguridad revisando el código existente, hazlo sin pedir preguntas innecesarias.
- Antes de un cambio grande, define qué debe seguir funcionando después.

## 2. Simplicidad primero

- Implementa la solución mínima que resuelva el problema.
- No agregues funcionalidades no solicitadas.
- No crees abstracciones para código de un solo uso sin una necesidad real.
- No dupliques lógica existente.
- Si una solución pequeña puede reemplazar una implementación mucho más compleja, prefiere la pequeña.
- No introduzcas dependencias nuevas si el proyecto ya puede resolverlo con su stack actual.

## 3. Cambios quirúrgicos

- Toca únicamente los archivos y líneas necesarios.
- No reformatees archivos completos por un cambio pequeño.
- No refactorices código no relacionado con la tarea.
- No borres comentarios o funciones que no entiendas.
- Mantén el estilo existente del proyecto.
- Si tu cambio deja imports, variables o funciones sin uso creados por tu propia modificación, límpialos.
- Si encuentras un problema no relacionado, repórtalo por separado; no lo arregles silenciosamente.

**Regla:** cada línea modificada debe poder relacionarse directamente con la tarea solicitada.

## 4. Trabajar con objetivos verificables

Para errores y cambios funcionales:

1. Identifica cómo se reproduce o cuál es el estado actual.
2. Define el resultado esperado.
3. Implementa el cambio mínimo.
4. Verifica el resultado.
5. Comprueba que no rompiste el flujo relacionado.

No marques una tarea como terminada solo porque el código "se ve correcto".

---

# Protección de datos

## 5. Datos reales y datos de prueba

- Trata todos los datos de Supabase como datos reales salvo evidencia explícita de que son sintéticos.
- Nunca borres datos reales para realizar pruebas.
- Antes de un `DELETE`, `UPDATE` masivo o migración destructiva:
  - cuenta cuántos registros serán afectados;
  - identifica de forma inequívoca los registros objetivo;
  - revisa relaciones y `ON DELETE`;
  - verifica nuevamente después de ejecutar.
- Los datos sintéticos deben tener una marca reconocible, por ejemplo:
  - prefijo en nombre;
  - prefijo en slug;
  - rango de IDs reservado;
  - campo explícito de entorno/prueba.
- Nunca generes decenas de miles de datos sintéticos sin una estrategia de limpieza.
- Cuando una prueba de carga termine, elimina solo los registros marcados como prueba y verifica que los datos reales permanezcan.
- Para cambios grandes o de riesgo, conserva una vía de rollback antes de ejecutar.

---

# Supabase y seguridad

## 6. Base de datos

- Verifica tablas, columnas, constraints, índices y funciones antes de escribir SQL.
- Usa consultas acotadas; evita traer tablas completas al navegador.
- Para DDL o cambios permanentes de esquema, usa migraciones controladas.
- Después de una modificación de base de datos, ejecuta una consulta de verificación.
- No expongas `service_role`, secret keys, Access Tokens ni credenciales privadas en el frontend, repositorio, logs o documentación pública.
- Las funciones `SECURITY DEFINER` requieren revisión de permisos y validación explícita del usuario/rol.
- Mantén RLS y autorización como capas distintas: estar autenticado no significa estar autorizado.

## 7. Separación de roles

YummyPro separa claramente:

- **Administrador global:** este panel.
- **Negocio:** restaurante, supermercado, minimarket o profesional.
- **Cliente:** usuario del menú o experiencia pública.

Reglas:
- Un cliente no debe poder iniciar sesión como administrador o negocio.
- Un negocio no debe adquirir privilegios de administrador.
- Un administrador no debe ser tratado automáticamente como cliente.
- La creación de cuentas debe asignar el rol correcto desde el origen.
- Toda autorización sensible debe comprobarse también en backend/base de datos, no solo ocultando botones.

---

# Rendimiento y escala

## 8. Diseñar para muchos negocios y pedidos

Asume que la plataforma puede crecer a cientos de miles de negocios y millones de registros.

- Nunca cargues todos los negocios, pedidos, productos o clientes al navegador.
- Usa paginación del lado del servidor.
- Para páginas profundas, considera cursor/keyset pagination en lugar de offsets gigantes.
- Usa búsqueda del lado del servidor para selectores grandes.
- Renderiza solo los registros visibles.
- Carga módulos pesados únicamente cuando se necesiten.
- Evita bloquear el primer render del panel con métricas históricas o módulos secundarios.
- Ejecuta tareas independientes en paralelo solo cuando no compitan por recursos críticos.
- Usa caché o rollups/agregados para métricas históricas que no necesitan recalcularse en cada carga.
- Antes de agregar un índice, confirma qué consulta lo necesita.
- Para consultas lentas, mide con `EXPLAIN (ANALYZE, BUFFERS)` cuando sea seguro.
- Compara tiempos antes y después de optimizar.
- No declares una mejora de rendimiento sin una medición o una evidencia observable.

## 9. Frontend

- Mantén el panel responsivo en escritorio y móvil.
- No conviertas una lista grande en scroll infinito sin virtualización o paginación.
- Evita DOM masivo.
- No hagas múltiples llamadas idénticas durante el arranque.
- Evita listeners duplicados.
- Las secciones secundarias deben ser lazy/deferred cuando sea posible.
- Los botones y acciones principales deben seguir funcionando con pantalla pequeña.
- Un popup/modal debe bloquear correctamente la interacción con el fondo cuando corresponda.

---

# Pagos y suscripciones

## 10. Separar credenciales y flujos

- Las credenciales centrales del administrador para cobrar suscripciones de YummyPro son distintas de las credenciales que cada negocio usa para cobrar a sus clientes.
- No mezcles ambos flujos.
- Nunca muestres tokens privados al navegador.
- Los pagos confirmados deben validarse desde una fuente confiable del backend antes de conceder beneficios.
- Una cancelación o devolución no debe dejar estados inconsistentes entre pedido, pago y suscripción.

---

# Compatibilidad funcional

## 11. No romper módulos existentes

Al modificar una función compartida, revisa al menos sus consumidores directos.

Especial atención a:
- autenticación;
- navegación;
- negocios;
- planes y suscripciones;
- pedidos;
- pagos;
- productos y categorías;
- inventario;
- QR;
- notificaciones;
- módulos retail;
- módulo profesional;
- métricas del administrador.

Un arreglo localizado no debe cambiar el comportamiento de otro módulo sin una razón explícita.

---

# Versionado y Git

## 12. Commits

- Cada cambio funcional debe quedar en un commit descriptivo.
- No mezcles cambios no relacionados en el mismo commit.
- Evita commits gigantes si el trabajo puede separarse en unidades verificables.
- Antes de escribir un archivo existente, lee su versión actual para no sobrescribir cambios recientes.

## 13. Versión visible

- Incrementa la versión visible del frontend cuando haya un cambio funcional que el usuario necesite distinguir en producción.
- No incrementes la versión solo por documentación, comentarios o este archivo de reglas.
- La versión visible debe coincidir con el código publicado que se pretende verificar.

---

# Checklist antes de terminar

Para una tarea funcional, confirma lo que aplique:

- [ ] Revisé el código actual antes de modificarlo.
- [ ] El cambio es mínimo y relacionado con la tarea.
- [ ] No expuse secretos.
- [ ] No afecté datos reales innecesariamente.
- [ ] Verifiqué roles/permisos si hay autenticación o datos sensibles.
- [ ] Probé o verifiqué el flujo principal.
- [ ] Revisé móvil y escritorio si cambié UI.
- [ ] Medí antes/después si la tarea era de rendimiento.
- [ ] Verifiqué conteos antes/después si modifiqué datos masivamente.
- [ ] No rompí consumidores directos de funciones compartidas.
- [ ] Dejé el repositorio sin código temporal de prueba.
- [ ] Registré el cambio funcional en Git.

---

# Principio final

**Entender primero. Cambiar lo mínimo. Verificar siempre. Proteger los datos.**

Si una solución parece requerir reescribir una gran parte del sistema para corregir un problema pequeño, revisa el enfoque antes de continuar.
