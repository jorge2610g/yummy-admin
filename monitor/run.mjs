import {writeFile} from 'node:fs/promises';
import {checks} from './config.mjs';

async function probe(check){
 const started=Date.now();
 try{
  const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),10000);
  const response=await fetch(check.url,{method:check.method||'GET',headers:check.headers||{},signal:controller.signal,redirect:'follow'});clearTimeout(timer);
  const latencyMs=Date.now()-started;const body=check.method==='OPTIONS'?'':await response.text();
  const statusAllowed=check.reachableStatuses?check.reachableStatuses.includes(response.status):response.ok;
  let valid=statusAllowed;
  if(valid&&check.contains)valid=body.toLowerCase().includes(check.contains.toLowerCase());
  if(valid&&check.json){try{const value=JSON.parse(body);valid=Array.isArray(value)&&value.length>0}catch{valid=false}}
  if(valid&&check.jsonObject){try{const value=JSON.parse(body);valid=!!value&&typeof value==='object'&&!Array.isArray(value)}catch{valid=false}}
  const level=!valid?'critical':latencyMs>check.criticalMs?'critical':latencyMs>check.warnMs?'warning':'operational';
  const message=!valid?'Respuesta o contenido inválido':level==='critical'?'Respuesta críticamente lenta':level==='warning'?'Respuesta lenta':'Operativo';
  return {...check,url:check.url.replace(/\?.*/,''),httpStatus:response.status,latencyMs,level,ok:valid,message};
 }catch(error){return {...check,url:check.url.replace(/\?.*/,''),httpStatus:0,latencyMs:Date.now()-started,level:'critical',ok:false,message:error.name==='AbortError'?'Tiempo de espera agotado':error.message}}
}

const services=await Promise.all(checks.map(probe));
const overall=services.some(x=>x.level==='critical')?'critical':services.some(x=>x.level==='warning')?'warning':'operational';
const diagnoses=services.filter(x=>x.level!=='operational').map(x=>({service:x.name,possibleCause:x.httpStatus>=500?'El servicio remoto respondió con un error interno.':x.httpStatus===0?'La conexión agotó el tiempo o el dominio no respondió.':x.ok&&x.level!=='operational'?'El servicio funciona, pero supera el umbral normal de latencia.':'La respuesta no cumple el contrato esperado.',recommendedAction:x.id.startsWith('supabase_')?'Revisar el estado del servicio y los logs de Supabase.':x.id==='pagos'?'Revisar la Edge Function y la conexión con Mercado Pago.':'Revisar el último despliegue y la consola del navegador.'}));
const result={system:'Express Delivery',checkedAt:new Date().toISOString(),commit:process.env.GITHUB_SHA||'local',overall,services,diagnoses};
await writeFile(process.env.MONITOR_OUTPUT||'monitor-result.json',JSON.stringify(result,null,2));
console.log(JSON.stringify(result,null,2));
if(overall==='critical')process.exitCode=1;
