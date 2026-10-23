0000000000001fe0 <lj_opt_cse>:
    1fe0:	push   %rbx
    1fe1:	sub    $0x30,%rsp
    1fe5:	movzbl 0xbd(%rcx),%ebx
    1fec:	mov    0xb8(%rcx),%r9d
    1ff3:	movzbl %bl,%r11d
    1ff7:	testb  $0x2,0xaa(%rcx)
    1ffe:	je     2068 <lj_opt_cse+0x88>
    2000:	movzwl 0xb8(%rcx),%r8d
    2008:	movzwl 0xba(%rcx),%eax
    200f:	movzwl 0x192(%rcx,%r11,2),%edx
    2018:	cmp    %ax,%r8w
    201c:	cmovb  %eax,%r8d
    2020:	cmp    %edx,%r8d
    2023:	jae    2068 <lj_opt_cse+0x88>
    2025:	mov    0x20(%rcx),%r10
    2029:	jmp    2049 <lj_opt_cse+0x69>
    202b:	cs nopw 0x0(%rax,%rax,1)
    2035:	data16 cs nopw 0x0(%rax,%rax,1)
    2040:	movzwl 0x6(%rax),%edx
    2044:	cmp    %edx,%r8d
    2047:	jae    2068 <lj_opt_cse+0x88>
    2049:	mov    %edx,%eax
    204b:	lea    (%r10,%rax,8),%rax
    204f:	cmp    %r9d,(%rax)
    2052:	jne    2040 <lj_opt_cse+0x60>
    2054:	movzbl 0x4(%rax),%eax
    2058:	shl    $0x18,%eax
    205b:	add    %edx,%eax
    205d:	add    $0x30,%rsp
    2061:	pop    %rbx
    2062:	ret
    2063:	nopl   0x0(%rax,%rax,1)
    2068:	mov    0xc(%rcx),%edx
    206b:	cmp    0x150(%rcx),%edx
    2071:	jae    20bf <lj_opt_cse+0xdf>
    2073:	lea    0x1(%rdx),%eax
    2076:	add    $0xc8,%r11
    207d:	mov    %edx,%r8d
    2080:	mov    %eax,0xc(%rcx)
    2083:	mov    0x20(%rcx),%rax
    2087:	lea    (%rax,%r8,8),%r8
    208b:	movzwl 0x2(%rcx,%r11,2),%eax
    2091:	mov    %r9d,(%r8)
    2094:	mov    %ax,0x6(%r8)
    2099:	movzbl 0xbc(%rcx),%eax
    20a0:	mov    %dx,0x2(%rcx,%r11,2)
    20a6:	mov    %bl,0x5(%r8)
    20aa:	or     %al,0xb6(%rcx)
    20b0:	mov    %al,0x4(%r8)
    20b4:	shl    $0x18,%eax
    20b7:	add    %edx,%eax
    20b9:	add    $0x30,%rsp
    20bd:	pop    %rbx
    20be:	ret
    20bf:	mov    %r11,0x28(%rsp)
    20c4:	mov    %edx,0x24(%rsp)
    20c8:	mov    %r9d,0x20(%rsp)
    20cd:	mov    %rcx,0x40(%rsp)
    20d2:	call   20d7 <lj_opt_cse+0xf7>
    20d7:	mov    0x40(%rsp),%rcx
    20dc:	mov    0x28(%rsp),%r11
    20e1:	mov    0x24(%rsp),%edx
    20e5:	mov    0x20(%rsp),%r9d
    20ea:	movzbl 0xbd(%rcx),%ebx
    20f1:	jmp    2073 <lj_opt_cse+0x93>
    20f3:	xchg   %ax,%ax
    20f5:	data16 cs nopw 0x0(%rax,%rax,1)

