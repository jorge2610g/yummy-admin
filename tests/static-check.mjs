import {readFileSync} from 'node:fs';
for(const file of ['index.html','panel.html','panel/index.html']){
  const html=readFileSync(file,'utf8');
  if(!/<!doctype html>/i.test(html)||!/<\/html>/i.test(html))throw new Error(`${file}: HTML incompleto`);
  if(file==='index.html'){
    if(!html.includes('data-theme'))throw new Error(`${file}: falta data-theme`);
    if(!html.includes('SB_URL'))throw new Error(`${file}: falta SB_URL`);
    for(const marker of ['data-tab="customers"','loadAdminOverview','openRestaurantProfile','restaurant_order_status_events','metricRestaurants','metricActiveSubscriptions','metricOrders','metricTotalSales','value="promotions"','value="reviews"']){
      if(!html.includes(marker))throw new Error(`${file}: falta módulo o indicador ${marker}`);
    }
    for(const removed of ['data-tab="kitchenAdmin"','data-tab="financeAdmin"','data-tab="inventoryAdmin"','data-tab="promotionsAdmin"','data-tab="reviewsAdmin"']){
      if(html.includes(removed))throw new Error(`${file}: todavía aparece opción eliminada ${removed}`);
    }
  }
}
