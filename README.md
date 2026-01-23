# isAnAdminHow

# Local Admin Path Resolver

This tool is a PowerShell-based diagnostic script that determines **whether a given Active Directory user has local administrator rights on a specified Windows machine**, and **through which exact chain of groups or nested groups** those rights might be granted.

It is specifically designed for complex enterprise domains where:

- Local Administrator group membership may involve **nested local groups**.
- AD group membership may be **deeply nested and non-obvious**.
- Traditional checks (`net localgroup administrators`, `Get-LocalGroupMember`, etc.) fail to explain *why* someone is an admin.
- `tokenGroups` cannot be queried due to domain policy restrictions.

The script works without requiring RSAT on the remote machine, and avoids problematic AD attributes like `tokenGroups`.

---

## Purpose

The script answers the question:

> **“Is user X a local admin on machine Y? If so, *exactly why*?”**

This includes:

- Direct membership
- Local nested groups (Russian-doll structures)
- AD group membership via fully expanded `memberOf` recursion

You get a clear, auditable chain such as:

```
Administrators -> Local Ophth Admins -> MTW\Ophth-Superusers
```

or a clean:

```
No local admin detected.
```

---

## 🔧 How It Works

### 1. **Local AD queries (on the machine running the script)**

The script:

1. Calls `Get-ADUser -Identity <user> -Properties SID, MemberOf`
2. Recursively expands all AD groups via `Get-ADGroup -Properties MemberOf`
3. Collects all group SIDs the user belongs to
4. Prints a full list of those groups for visibility

This avoids problematic AD attributes like `tokenGroups`.

### 2. **Remote local machine queries**

Using `Invoke-Command`, the script:

1. Connects to the target machine
2. Enumerates the **local Administrators** group
3. Recursively expands any **local groups** nested under Administrators
4. Checks:
   - If the user’s SID appears directly
   - If any AD group SID appears at any nesting level

### 3. **Outputs detailed results**

Each hit includes:

- Machine name  
- User  
- Whether access is via direct membership or a group  
- The SID that matched  
- Full **path** from `Administrators` to the match  

Example:

```
SourceType : Group membership
SourceName : MYDOM\SalesDept-Admin
Path       : Administrators -> Local-Admins -> MYDOM\SalesDept-Admin
```

---

## Requirements

### On the machine running the script:

- PowerShell 5.1+
- RSAT ActiveDirectory module installed
- Domain-joined machine with rights to:
  - Query AD users
  - Query AD groups

### On the target machine:

- PowerShell Remoting enabled (`WinRM`)
- Ability to run `Get-LocalGroupMember`
- You must have privileges to query local groups remotely

---

## Usage

```
.\Get-UserLocalAdminSource.ps1
Enter the computer name: PC175
Enter the user (samAccountName or UPN, e.g. john.smith): john.smith
```

### Outputs include:

- A list of all AD groups processed  
- A table showing whether the user is a local admin  
- The exact chain of groups leading to admin rights (if any)

---

## Expected Results

### If the user *is* an admin:
You get a clear chain of membership showing the exact path.

### If the user is *not* an admin:
You get:

```
SourceType : None
Explanation: No local admin via local Administrators group (including nested local groups) detected
```

### If AD membership is complex:
All AD groups are fully expanded (direct + nested).

---

## Limitations & Caveats

- **Does not evaluate User Rights Assignment (LUG policies)**  
  e.g., “Allow logon locally”, “Deny logon locally”  
  These do *not* grant admin rights and are out of scope.

- **Only evaluates the Administrators group**  
  Being a local admin = member (directly or indirectly) of Administrators.

- **Cannot resolve nested AD groups inside local groups**  
  (Windows does not allow enumerating AD-group internals locally.)  
  Instead, we match SIDs by comparing the user’s full AD group list.

- **Relies on AD visibility**  
  If `Get-ADUser` cannot see the user’s groups (e.g., restricted domain), results may be incomplete.

- **WinRM must be enabled** on target systems  
  If not, the script cannot query the local machine.

- **Does not check for transient or historical admin rights**  
  Only current effective rights.

---

## Testing Recommendations

- Test with a known local admin user to verify detection
- Test with a deeply nested AD group membership scenario
- Test with a user who has no admin access
- Verify remote access with:
  ```
  Test-WsMan <computername>
  ```

---

## License

MIT License — do whatever you want with it, just don’t blame the author when your domain policies make AD behave like a mood ring.

---

## Contributions

Pull requests, issues, and improvements are welcome.  
Especially from anyone dealing with nested-group hell in enterprise AD.

