package = 'shs'
version = 'dev-0'

source = {
    url = "git+https://github.com/Mehgugs/shs.git"
}

description = {
    summary = 'A really simple https server.'
    ,homepage = "https://github.com/Mehgugs/shs"
    ,license = 'MIT'
    ,maintainer = 'Magicks <m4gicks@gmail.com>'
    ,detailed = ""
}

dependencies = {
     'lua >= 5.3'
    ,'cqueues'
    ,'http'
    ,'lua-zlib'
}

build = {
     type = "builtin"
    ,modules = {
        shs = "shs.lua"
    }
}