$TTNumber=read-host "введите номер магазина - прим. 241"
$TTPassword=read-host "введите пароль"
[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding("utf-8")

#Подключение диска Документы для магазинов МПР
net use Z: "\\ad.modniy.org\change_r2\Документы для магазинов МПР" /user:modniy\magazin$TTNumber /persistent:yes
net use Y: "\\ad.modniy.org\change_r2\Change\Magazins\$TTNumber"   /user:modniy\magazin$TTNumber /persistent:yes

#Команда на отключение сетевого диска: net use Z: /delete, всех дисков: net use * /delete

 