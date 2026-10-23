0000000000001fe0 <lj_opt_cse>:
    1fe0:	push   %rbp
    1fe1:	push   %rdi
    1fe2:	push   %rsi
    1fe3:	push   %rbx
    1fe4:	sub    $0x38,%rsp
    1fe8:	movzbl 0xbd(%rcx),%ebp
    1fef:	mov    0xb8(%rcx),%r11d
    1ff6:	movzbl %bpl,%edi
    1ffa:	mov    %rcx,%r8
    1ffd:	testb  $0x2,0xaa(%rcx)
    2004:	je     2090 <lj_opt_cse+0xb0>
    200a:	movzwl 0xb8(%r8),%r9d
    2012:	movzwl 0xba(%r8),%eax
    201a:	movzwl 0x192(%rcx,%rdi,2),%ecx
    2022:	cmp    %ax,%r9w
    2026:	cmovb  %eax,%r9d
    202a:	cmp    %ecx,%r9d
    202d:	jae    2090 <lj_opt_cse+0xb0>
    202f:	mov    0x20(%r8),%rbx
    2033:	jmp    2049 <lj_opt_cse+0x69>
    2035:	data16 cs nopw 0x0(%rax,%rax,1)
    2040:	movzwl 0x6(%rdx),%ecx
    2044:	cmp    %ecx,%r9d
    2047:	jae    2090 <lj_opt_cse+0xb0>
    2049:	mov    %ecx,%eax
    204b:	lea    (%rbx,%rax,8),%rdx
    204f:	cmp    %r11d,(%rdx)
    2052:	jne    2040 <lj_opt_cse+0x60>
    2054:	movzbl 0x4(%rdx),%eax
    2058:	mov    %eax,%r10d
    205b:	and    $0x1f,%r10d
    205f:	cmp    $0x15,%r10b
    2063:	movzbl 0xbc(%r8),%r10d
    206b:	setne  %sil
    206f:	and    $0x1f,%r10d
    2073:	cmp    $0x15,%r10b
    2077:	sete   %r10b
    207b:	cmp    %r10b,%sil
    207e:	je     2040 <lj_opt_cse+0x60>
    2080:	shl    $0x18,%eax
    2083:	add    %ecx,%eax
    2085:	add    $0x38,%rsp
    2089:	pop    %rbx
    208a:	pop    %rsi
    208b:	pop    %rdi
    208c:	pop    %rbp
    208d:	ret
    208e:	xchg   %ax,%ax
    2090:	mov    0xc(%r8),%ebx
    2094:	cmp    0x150(%r8),%ebx
    209b:	jae    20ec <lj_opt_cse+0x10c>
    209d:	lea    0x1(%rbx),%eax
    20a0:	add    $0xc8,%rdi
    20a7:	mov    %ebx,%edx
    20a9:	mov    %eax,0xc(%r8)
    20ad:	mov    0x20(%r8),%rax
    20b1:	lea    (%rax,%rdx,8),%rdx
    20b5:	movzwl 0x2(%r8,%rdi,2),%eax
    20bb:	mov    %r11d,(%rdx)
    20be:	mov    %ax,0x6(%rdx)
    20c2:	movzbl 0xbc(%r8),%eax
    20ca:	mov    %bx,0x2(%r8,%rdi,2)
    20d0:	mov    %bpl,0x5(%rdx)
    20d4:	or     %al,0xb6(%r8)
    20db:	mov    %al,0x4(%rdx)
    20de:	shl    $0x18,%eax
    20e1:	add    %ebx,%eax
    20e3:	add    $0x38,%rsp
    20e7:	pop    %rbx
    20e8:	pop    %rsi
    20e9:	pop    %rdi
    20ea:	pop    %rbp
    20eb:	ret
    20ec:	mov    %r8,%rcx
    20ef:	mov    %r11d,0x2c(%rsp)
    20f4:	mov    %r8,0x60(%rsp)
    20f9:	call   20fe <lj_opt_cse+0x11e>
    20fe:	mov    0x60(%rsp),%r8
    2103:	mov    0x2c(%rsp),%r11d
    2108:	movzbl 0xbd(%r8),%ebp
    2110:	jmp    209d <lj_opt_cse+0xbd>
    2112:	nopl   (%rax)
    2115:	data16 cs nopw 0x0(%rax,%rax,1)

