import {readFileSync} from 'node:fs';
for(const file of ['index.html','panel.html','panel/index.html']){const html=readFileSync(file,'utf8');if(!/<!doctype html>/i.test(html)||!/<\/html>/i.test(html))throw new Error(`${file}: HTML incompleto`);if(!file.includes('panel/')){if(!html.includes('data-theme'))throw new Error(`${file}: falta data-theme`);if(!html.includes('SB_URL'))throw new Error(`${file}: falta SB_URL`)}}
console.log('HTML administrativo validado');
