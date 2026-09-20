export const checks=[
 {id:'cliente',name:'Cliente',url:'https://menu.yummypro.online/?demo=1',contains:'Restaurante Demo',warnMs:800,criticalMs:5000},
 {id:'restaurante',name:'Restaurante',url:'https://web.yummypro.online/',contains:'Yummy',warnMs:800,criticalMs:5000},
 {id:'panel_restaurante',name:'Panel restaurante',url:'https://web.yummypro.online/panel/',contains:'Panel',warnMs:800,criticalMs:5000},
 {id:'admin',name:'Administración',url:'https://admin.yummypro.online/',contains:'Panel',warnMs:800,criticalMs:5000},
 {id:'supabase_api',name:'Supabase Data API',url:'https://gulctljitzlwokqydigx.supabase.co/rest/v1/restaurants?select=id&active=eq.true&limit=1',json:true,headers:{apikey:'sb_publishable__moppTxObowifx6rJbW_tw_3GiCkqhG'},warnMs:800,criticalMs:5000},
 {id:'supabase_auth',name:'Supabase Auth',url:'https://gulctljitzlwokqydigx.supabase.co/auth/v1/health',jsonObject:true,headers:{apikey:'sb_publishable__moppTxObowifx6rJbW_tw_3GiCkqhG'},warnMs:800,criticalMs:5000},
 {id:'supabase_storage',name:'Supabase Storage',url:'https://gulctljitzlwokqydigx.supabase.co/storage/v1/status',headers:{apikey:'sb_publishable__moppTxObowifx6rJbW_tw_3GiCkqhG'},warnMs:800,criticalMs:5000},
 {id:'pagos',name:'Servicio de pagos',url:'https://gulctljitzlwokqydigx.supabase.co/functions/v1/create-restaurant-payment',method:'OPTIONS',reachableStatuses:[200,204,400,401,403,404,405],warnMs:1200,criticalMs:5000}
];
