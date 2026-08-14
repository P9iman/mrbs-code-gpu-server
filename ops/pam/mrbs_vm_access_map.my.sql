-- MySQL helper table for VM-to-MRBS-room mapping used by ops/pam/mrbs_ssh_booking_check.sh

CREATE TABLE IF NOT EXISTS mrbs_vm_access_map
(
  vm_hostname varchar(191) NOT NULL,
  room_id int NOT NULL,

  PRIMARY KEY (vm_hostname),
  KEY idx_room_id (room_id),
  CONSTRAINT fk_vm_map_room
    FOREIGN KEY (room_id)
    REFERENCES mrbs_room(id)
    ON UPDATE CASCADE
    ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Example mapping:
-- INSERT INTO mrbs_vm_access_map(vm_hostname, room_id) VALUES ('gpu-vm-01', 12);
