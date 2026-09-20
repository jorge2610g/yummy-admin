import {readFile} from 'node:fs/promises';
const token=process.env.WHATSAPP_TOKEN,phoneId=process.env.WHATSAPP_PHONE_NUMBER_ID,to=process.env.WHATSAPP_TO;
if(!token||!phoneId||!to){console.log('WhatsApp no configurado; se conserva la incidencia en GitHub.');process.exit(0)}
const report=JSON.parse(await readFile(process.env.MONITOR_OUTPUT||'monitor-result.json','utf8'));
const failed=report.services.filter(x=>x.level!=='operational');
const text=['🔴 INCIDENTE · EXPRESS DELIVERY',`Estado: ${report.overall.toUpperCase()}`,`Detectado: ${new Date(report.checkedAt).toLocaleString('es-CL',{timeZone:'America/Santiago'})}`,...failed.map(x=>`${x.name}: ${x.message} · ${x.latencyMs} ms · HTTP ${x.httpStatus}`),`Commit: ${report.commit.slice(0,12)}`].join('\n');
const response=await fetch(`https://graph.facebook.com/v23.0/${phoneId}/messages`,{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',to,type:'text',text:{preview_url:false,body:text}})});
if(!response.ok)throw new Error(`WhatsApp rechazó la alerta (${response.status}): ${await response.text()}`);
console.log('Alerta enviada a WhatsApp');
