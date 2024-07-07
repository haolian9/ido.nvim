a poorly-written `iedit` impl

## design choices, features, limits
TBD 

## status
* just works

## prerequisites
* nvim 0.10.*
* haolian9/infra.nvim
* haolian9/puff.nvim
* haolian9/beckon.nvim
* haolian9/squirrel.nvim

## usage
here's my personal config
```
do --ido
  m.x("I", ":lua require'ido'.activate_interactively()<cr>")
  m.x("A", ":lua require'ido'.activate()<cr>")

  do --:Ido
    local spell = cmds.Spell("Ido", function(args, ctx)
      local op = (function()
        if args.op ~= nil then return args.op end
        if ctx.range == 0 then return "deactivate" end
        return "activate"
      end)()
      assert(require("ido")[op])()
    end)
    spell:add_arg("op", "string", false, nil, cmds.ArgComp.constant({ "activate", "activate_interactively", "deactivate" }))
    spell:enable("range")
    cmds.cast(spell)
  end
end
```

## credits
* i learnt about this `iedit` from [iedit.nvim](https://github.com/altermo/iedit.nvim), yet still rolled my own
* https://www.masteringemacs.org/article/iedit-interactive-multi-occurrence-editing-in-your-buffer

## about the name

![ido](https://github.com/haolian9/zongzi/assets/6236829/823975ca-9300-4f50-9d2c-94a048e1539e)
