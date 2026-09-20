const { defineConfig } = require('@playwright/test');
module.exports = defineConfig({testDir:'./tests',timeout:30000,retries:1,workers:1,use:{baseURL:process.env.APP_URL||'https://admin.yummypro.online',trace:'retain-on-failure',screenshot:'only-on-failure'},reporter:[['line'],['html',{open:'never'}]]});
