open util/boolean

sig Addr {
	var balance: Int,
}

sig Deposit {
	value: Int,
	expiration: Int,
	arbiter: Addr,
	depositor: lone Addr,
}

one sig Collateralization in Addr {
	var deposits: set Deposit,
	var epoch: Int,
}

fact {
	all d: Deposit {
		d.value > 0
		d.expiration >= 0
		d.depositor != Collateralization
	}
	Collateralization.epoch >= 0
	let activeDeposits = {d: Collateralization.deposits | some d.depositor} |
		Collateralization.balance >= (sum d: activeDeposits | d.value)
}

fact {
	always all a: Addr | a.balance >= 0
	always Collateralization.epoch' >= Collateralization.epoch
	all d: Deposit | eventually d in Collateralization.deposits
}

pred transfer[from, to: Addr, n: Int] {
	n > 0
	from.balance >= n
	from.balance' = sub[from.balance, n]
	to.balance' = add[to.balance, n]
}

pred prepareDeposit[sender: Addr, fund: Bool] {
	some d: Deposit {
		d not in Collateralization.deposits
		Collateralization.epoch < d.expiration
		Collateralization.deposits' = Collateralization.deposits + d
		isTrue[fund] => {
			d.depositor = sender
			transfer[sender, Collateralization, d.value]
		} else {
			no d.depositor
			Collateralization.balance' = Collateralization.balance
		}
	}
}

pred fund[sender: Addr, d: Deposit] {
	d in Collateralization.deposits
	Collateralization.epoch < d.expiration
	no d.depositor
	d.depositor' = sender
	transfer[sender, Collateralization, d.value]
}

pred withdraw[sender: Addr, d: Deposit] {
	d in Collateralization.deposits
	Collateralization.epoch >= d.expiration
	Collateralization.deposits' = Collateralization.deposits - d
	transfer[Collateralization, d.depositor, d.value]
}

pred slash[a: Addr, d: Deposit] {
	d in Collateralization.deposits
	some d.depositor
	d.arbiter = a
	d.expiration < Collateralization.epoch
	Collateralization.deposits' = Collateralization.deposits - d
	Collateralization.balance' = sub[Collateralization.balance, d.value]
}

run {} for 3 but 3 Int

pred skip {
	Collateralization.balance' = Collateralization.balance
	Collateralization.deposits' = Collateralization.deposits
}

fact transitions {
	always (
		(some sender: Addr, fund: Bool | prepareDeposit[sender, fund]) or
		(some sender: Addr, d: Deposit | fund[sender, d]) or
		(some sender: Addr, d: Deposit | withdraw[sender, d]) or
		(some sender: Addr, d: Deposit | slash[sender, d]) or
		skip
	)
}

check {
	always (let activeDeposits = {d: Collateralization.deposits | some d.depositor} |
		Collateralization.balance >= (sum d: activeDeposits | d.value))
	// deposit can only be removed after expiration
	always all d: Collateralization.deposits |
		(Collateralization.epoch >= d.expiration) releases (d in Collateralization.deposits)
} for 3 but 5 steps, 3 Int
