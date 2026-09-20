const {defineConfig}=require('@playwright/test');
module.exports=defineConfig({testDir:'.',testMatch:'production.spec.js',timeout:40000,retries:1,workers:1,use:{trace:'retain-on-failure',screenshot:'only-on-failure'},reporter:[['line'],['html',{outputFolder:'production-report',open:'never'}]]});
