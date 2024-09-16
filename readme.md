a poorly-written `iedit` impl

https://github.com/haolian9/zongzi/assets/6236829/e0bb9e13-359c-4229-a694-936ec3e30b96


## design choices, features, limits
* interactive
  * [x] input the pattern, respect `^` and `$`
  * [x] select a TSNode region
  * [x] select a line range
  * ~~opt-in/out on each occurrence~~
* one and only one active session for each buffer
* only one truth of source, all others are replicas
* there is a delay time on syncing
* syncing changes to the buffer directly rather than changing extmarks
  * i found it's hard to maintance the integrity between buffer content and extmark, during
    user editing, especially undo/redo .
* vim-flavored pattern
* compatible with **utf-8** characters
* there are session flavors:
  * ElasticSession: `[changeable]` where the `changeable` is captured by the input pattern, it can be zero-range
  * CoredSession: `[changeable][core][changeable]` where the `core` is captured by the input pattern, the changeable parts are zero-range at the begining
* ~~record ops by vim.on_key and replay them to all replicas~~

## status
* WIP: i'm not happy with its impl and UX

## prerequisites
* nvim 0.10.*
* haolian9/infra.nvim
* haolian9/puff.nvim

## usage
here's my personal config
```
do
  m.x("gii", ":lua require'ido'.activate('ElasticSession')<cr>")
  m.x("gio", ":lua require'ido'.activate('CoredSession')<cr>")
  m.n("gi0", function() require("ido").goto_truth() end)

  do --:Ido
    local spell = cmds.Spell("Ido", function(args, ctx)
      local op = (function()
        if args.op ~= nil then return args.op end
        if ctx.range == 0 then return "deactivate" end
        return "activate"
      end)()
      assert(require("ido")[op])()
    end)
    spell:add_arg("op", "string", false, nil, cmds.ArgComp.constant({ "activate", "deactivate" }))
    spell:enable("range")
    cmds.cast(spell)
  end
end
```

## credits
* i learnt about the `iedit` concept from [iedit.nvim](https://github.com/altermo/iedit.nvim), yet still rolled my own
* https://www.masteringemacs.org/article/iedit-interactive-multi-occurrence-editing-in-your-buffer

## about the name

![ido](https://github.com/haolian9/zongzi/assets/6236829/823975ca-9300-4f50-9d2c-94a048e1539e)
