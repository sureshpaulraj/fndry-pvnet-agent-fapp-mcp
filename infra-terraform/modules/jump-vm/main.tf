# ─── Jump VM Module ──────────────────────────────────────────────────────────
# Linux VM for testing VNet-internal resources (MCP Container App, PEs)
# Uses SSH key auth (no password) and has a public IP for access.

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type        = string
  description = "Subnet ID for the VM NIC (jumpbox-subnet)"
}

variable "vm_name" {
  type    = string
  default = "jumpbox-vm"
}

variable "vm_size" {
  type    = string
  default = "Standard_B1s"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the VM admin user"
}

# ─── Public IP ───────────────────────────────────────────────────────────────
resource "azurerm_public_ip" "jumpbox" {
  name                = "${var.vm_name}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ─── NSG — allow SSH from caller only ────────────────────────────────────────
resource "azurerm_network_security_group" "jumpbox" {
  name                = "${var.vm_name}-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# ─── NIC ─────────────────────────────────────────────────────────────────────
resource "azurerm_network_interface" "jumpbox" {
  name                = "${var.vm_name}-nic"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_network_interface_security_group_association" "jumpbox" {
  network_interface_id      = azurerm_network_interface.jumpbox.id
  network_security_group_id = azurerm_network_security_group.jumpbox.id
}

# ─── Linux VM ────────────────────────────────────────────────────────────────
resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                            = var.vm_name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true

  network_interface_ids = [
    azurerm_network_interface.jumpbox.id,
  ]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Install curl + jq on first boot for easy MCP testing
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y curl jq
  EOF
  )
}

# ─── Outputs ─────────────────────────────────────────────────────────────────
output "public_ip" {
  value = azurerm_public_ip.jumpbox.ip_address
}

output "private_ip" {
  value = azurerm_network_interface.jumpbox.private_ip_address
}

output "admin_username" {
  value = var.admin_username
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.jumpbox.name
}
